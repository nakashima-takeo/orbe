import AVFoundation
import Foundation
import OrbeSound

/// 通知音を実際に鳴らす層。合成（決定論・純関数）と切り離してあり、テストはここをフェイクへ差し替える。
protocol AgentSoundPlaying: AnyObject {
  func play(_ source: ResolvedSource, event: AgentSoundEvent, volume: Int)
  /// 鳴っている音を止める（サブパレットの「なし」行・行の移動での鳴らし直し）。
  func stopPreview()
}

/// 再生層の生成点。テストの隔離ハーネスがここを差し替える——スピーカーは実 state dir と同じく
/// 「テストが触ってはいけない管理外の実環境」なので、永続ファイルの `fileURLOverride` 群と同じ扱いにする。
enum AgentSoundOutput {
  nonisolated(unsafe) static var makeOverride: (() -> AgentSoundPlaying)?

  static func make() -> AgentSoundPlaying { makeOverride?() ?? SoundPlayer() }
}

/// `AVAudioEngine` + `AVAudioPlayerNode` 1 本の再生層。
///
/// - 合成は同期で数 ms なので専用の直列キューへ逃がし、main を止めない。エンジン操作も同じキューへ
///   直列化する（`AVAudioEngine` は同時操作を許さない）。
/// - エンジンは**初回再生で遅延起動**し、アイドルが続けば止める。ターミナルとして 1 日中起動している
///   アプリで、鳴っていない間もレンダーコールバックを回し続けない。
/// - 出力デバイスの切替（ヘッドホン抜き差し）は `AVAudioEngineConfigurationChange` で組み直す。
///   サンプルレートが変わりうるので合成済みバッファのキャッシュも捨てる。
final class SoundPlayer: AgentSoundPlaying {
  private struct CacheKey: Hashable {
    let source: ResolvedSource
    let event: AgentSoundEvent
    let volume: Int
  }

  /// **鳴り終わってから**この秒数だけ次が来なければエンジンを止める。起点を再生開始でなく終了に取るのは、
  /// 音の長さが合成音（〜2 秒）と取り込み音（最大 `SoundImport.maxDuration`）で桁違いだから
  /// ——固定の待ち時間に「最長の音は何秒か」を織り込むと、上限を動かすたびここが追随を要求する。
  private let idleTimeout: TimeInterval = 5

  private let queue = DispatchQueue(label: "dev.orbe.sound", qos: .userInitiated)
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  /// プレイヤーノードを繋いだフォーマット。バッファはこれと**同じインスタンス**で組む
  /// （同じ式で 2 度作ると、片方だけ触ったときに `scheduleBuffer` が不一致で落ちる）。
  private var format: AVAudioFormat?
  /// 合成音の再生用バッファ。試聴サブパレットは 12 案 × 2 イベントを全部通すので、上限が無いと
  /// 1 日中起動しているプロセスに二度と使われない波形が溜まり続ける（→ `store`）。
  /// 取り込み音は**載せない**（→ `buffer`）。
  private var cache: [CacheKey: AVAudioPCMBuffer] = [:]
  private var idleStop: DispatchWorkItem?
  private var configurationObserver: NSObjectProtocol?

  deinit {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
  }

  func play(_ source: ResolvedSource, event: AgentSoundEvent, volume: Int) {
    queue.async { [weak self] in self?.playOnQueue(source, event: event, volume: volume) }
  }

  func stopPreview() {
    queue.async { [weak self] in self?.player?.stop() }
  }

  // MARK: - キュー上（直列）

  private func playOnQueue(_ source: ResolvedSource, event: AgentSoundEvent, volume: Int) {
    // 取り込み済みファイルが読めないときは**紋章の同 event 音**へ落として鳴らす。設定の不整合
    // （手編集・`orb config` 直書き）を「無音」で表さない——「鳴らない」の担体はオン/オフだけ。
    guard let player = startedPlayer(),
      let buffer = buffer(source: source, event: event, volume: volume)
        ?? buffer(source: .synth(.default), event: event, volume: volume)
    else { return }
    // 前の音を止めてから差し替える。深層・紋章・鋼は 2 秒近くあるので、↑↓ の連打で団子にならない。
    player.stop()
    player.scheduleBuffer(buffer, at: nil, options: [])
    player.play()
    scheduleIdleStop(after: Double(buffer.frameLength) / buffer.format.sampleRate)
  }

  /// 起動済みのプレイヤー（未構築なら現在の出力フォーマットに合わせて組み、遅延起動する）。
  private func startedPlayer() -> AVAudioPlayerNode? {
    if engine == nil { build() }
    guard let engine, let player else { return nil }
    if !engine.isRunning {
      do { try engine.start() } catch { return nil }
    }
    return player
  }

  private func build() {
    let engine = AVAudioEngine()
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    // 出力フォーマットに合わせた rate で合成する（44.1k / 48k どちらでも同じ式で正しい）。
    guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
    else { return }
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      self?.queue.async { self?.teardown() }  // 次の再生で今の出力デバイスに合わせて組み直す
    }
    self.engine = engine
    self.player = player
    self.format = format
  }

  private func buffer(source: ResolvedSource, event: AgentSoundEvent, volume: Int)
    -> AVAudioPCMBuffer?
  {
    // 取り込み音はキャッシュしない。保存名は取り込みごとの一意名なので、載せると聴き比べたぶんだけ
    // 二度と当たらないキーが積み上がる（GC が実体を消しても波形だけ残る）。読み戻し＋マスタ末尾の実測は
    // 10 秒でも合成 1 音より軽く、専用キュー上なので main も止めない——載せない方が素直に有界。
    let key = CacheKey(source: source, event: event, volume: volume)
    let cacheable = key.source.isSynth
    if cacheable, let cached = cache[key] { return cached }
    guard let format,
      let samples = renderedSamples(source, event: event, volume: volume, format: format),
      !samples.isEmpty,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channels = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    // モノラルの結果を 2ch へ複製する。
    samples.withUnsafeBufferPointer { mono in
      guard let base = mono.baseAddress else { return }
      for channel in 0..<Int(format.channelCount) {
        channels[channel].update(from: base, count: mono.count)
      }
    }
    if cacheable { store(buffer, for: key) }
    return buffer
  }

  /// 鳴らすモノラルサンプル列。合成はその場で組み、取り込み済みは `sounds/` から読み戻して
  /// **マスタ末尾だけを合成音と同じ 1 実装で通す**（音量ゲイン → コンプレッサ）。だから案と
  /// カスタムを切り替えても鳴りの強さも音量ノブの手応えも揃う。読めなければ nil（呼び出し側で退避）。
  private func renderedSamples(
    _ source: ResolvedSource, event: AgentSoundEvent, volume: Int, format: AVAudioFormat
  ) -> [Float]? {
    switch source {
    case .synth(let family):
      return SoundRenderer.render(
        family: family, event: event, volume: volume, sampleRate: format.sampleRate)
    case .imported(let file):
      guard let url = CustomSoundStore.url(for: file),
        let mono = AudioFileDecoder.monoSamples(
          of: url, sampleRate: format.sampleRate, maxSeconds: SoundImport.maxDuration)
      else { return nil }
      return SoundRenderer.finalize(mono, volume: volume, sampleRate: format.sampleRate)
    }
  }

  /// キャッシュへ載せる。同時に使う音量は常に 1 つ（実効値、または試聴中の実効値）なので、
  /// 別音量のぶんは載せた瞬間に捨てる——これで上限は 12 案 × 2 イベントに固定される。
  private func store(_ buffer: AVAudioPCMBuffer, for key: CacheKey) {
    cache = cache.filter { $0.key.volume == key.volume }
    cache[key] = buffer
  }

  /// `playback` はいま鳴らし始めたバッファの長さ。停止予約はその後ろに置く
  /// ——`AVAudioPlayerNode.stop()` は再生中バッファを破棄するので、鳴り終わる前に踏むと音が切れる。
  private func scheduleIdleStop(after playback: TimeInterval) {
    idleStop?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.player?.stop()
      self.engine?.pause()  // レンダーコールバックを止める（グラフは残すので次回は即再開できる）
    }
    idleStop = work
    queue.asyncAfter(deadline: .now() + playback + idleTimeout, execute: work)
  }

  /// 出力デバイスが変わった。エンジンを捨て、次の再生で新しいフォーマットに合わせて組み直す。
  private func teardown() {
    idleStop?.cancel()
    idleStop = nil
    player?.stop()
    engine?.stop()
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    engine = nil
    player = nil
    format = nil
    cache.removeAll()
  }
}
