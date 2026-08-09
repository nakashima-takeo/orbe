import AVFoundation
import Foundation

/// 通知音を実際に鳴らす層。合成（決定論・純関数）と切り離してあり、テストはここをフェイクへ差し替える。
protocol AgentSoundPlaying: AnyObject {
  func play(_ family: NotificationSound, event: AgentSoundEvent, volume: Int)
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
    let family: NotificationSound
    let event: AgentSoundEvent
    let volume: Int
    let sampleRate: Double
  }

  /// 最後の再生からこの秒数だけ鳴らなければエンジンを止める（最長の音でも約 2.2 秒で鳴り終わる）。
  private let idleTimeout: TimeInterval = 5

  private let queue = DispatchQueue(label: "dev.orbe.sound", qos: .userInitiated)
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var sampleRate: Double = 0
  private var cache: [CacheKey: AVAudioPCMBuffer] = [:]
  private var idleStop: DispatchWorkItem?
  private var configurationObserver: NSObjectProtocol?

  deinit {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
  }

  func play(_ family: NotificationSound, event: AgentSoundEvent, volume: Int) {
    queue.async { [weak self] in self?.playOnQueue(family, event: event, volume: volume) }
  }

  func stopPreview() {
    queue.async { [weak self] in self?.player?.stop() }
  }

  // MARK: - キュー上（直列）

  private func playOnQueue(_ family: NotificationSound, event: AgentSoundEvent, volume: Int) {
    guard let player = startedPlayer(),
      let buffer = buffer(family: family, event: event, volume: volume)
    else { return }
    // 前の音を止めてから差し替える。深層・紋章・鋼は 2 秒近くあるので、↑↓ の連打で団子にならない。
    player.stop()
    player.scheduleBuffer(buffer, at: nil, options: [])
    player.play()
    scheduleIdleStop()
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
    sampleRate = rate
  }

  private func buffer(family: NotificationSound, event: AgentSoundEvent, volume: Int)
    -> AVAudioPCMBuffer?
  {
    let key = CacheKey(family: family, event: event, volume: volume, sampleRate: sampleRate)
    if let cached = cache[key] { return cached }
    let samples = SoundRenderer.render(
      family: family, event: event, volume: volume, sampleRate: sampleRate)
    guard !samples.isEmpty,
      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channels = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    // モノラルの合成結果を 2ch へ複製する。
    samples.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return }
      for channel in 0..<Int(format.channelCount) {
        channels[channel].update(from: base, count: source.count)
      }
    }
    cache[key] = buffer
    return buffer
  }

  private func scheduleIdleStop() {
    idleStop?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.player?.stop()
      self.engine?.pause()  // レンダーコールバックを止める（グラフは残すので次回は即再開できる）
    }
    idleStop = work
    queue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
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
    sampleRate = 0
    cache.removeAll()
  }
}
