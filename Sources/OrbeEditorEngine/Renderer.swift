import AppKit
import Metal
import QuartzCore

/// 1 コマを組み立てて Metal へ符号化し、画面（または画面外）へ出す。描画スレッドだけが触る。
///
/// キャレットの点滅は時刻から決める。描くものが変わらなければ刻みを止め、焦点のある面は次に表示が切り替わる時刻にだけ
/// run loop のタイマーで自分を起こす（点滅だけが変わったコマの後は、すぐ止める）。
///
/// どの面のためにも待たない——面ごとに「画面に出ていないコマ」を数え、上限の面はそのコマを飛ばす（`nextDrawable` は
/// 実際には待たない）。GPU の空きも待たずに数える。飛ばしたコマは、画面に出た知らせを受けた時点で次の刻みを待たずに描く。
/// 位置は描く直前にコマの予定時刻で読む（指の出来事をできるだけ新しく入れる）。描くものが変わらないコマが続いたら、
/// その面の刻みを止め、箱に書かれて起こされたら、その場で 1 コマ描いてから刻みに戻る。
final class Renderer {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let gate: PipelineGate
  let fonts = FontRegistry()
  private var atlases: [AtlasKey: GlyphAtlas] = [:]
  private var slots: [Int: SurfaceSlot] = [:]
  /// 命令の列ごとの instance の buffer（使用中の印つき）。使用中の数が GPU に出して終わっていない命令の列の数。
  var buffers: [(buffer: MTLBuffer, busy: Bool)] = []
  private var frameCounter = 0
  /// 描画スレッドの時間制約に申告した表示の刻み（秒）。
  private var framePeriod: Double?
  /// GPU に出して終わっていない命令の列の上限。
  static let gpuLimit = 3
  /// 描くものが変わらないコマがこれだけ続いたら刻みを止める。
  static let idleTicksBeforePause = 2
  /// 起こされてその場で描くのに要る、次に画面に出る刻みまでの残り（命令を出し終える余裕 1ms と、1 コマの CPU の上限
  /// 1ms）。足りなければ次の刻みで描く。
  static let wakeBudget = 0.002
  /// 止めてから、ジェスチャーの要約を締めるまで（OS の momentum が続くか・main の詰まりが明けるかを見届ける）。
  static let gestureSettle = 0.3

  init(device: MTLDevice) {
    self.device = device
    queue = device.makeCommandQueue()!
    gate = PipelineGate(device: device) {
      RenderThread.shared.perform { $0.pipelinesDidBecomeReady() }
    }
  }

  // MARK: - 面の出入り

  func attach(
    id: Int, material: MaterialBox, scroll: ScrollBox, config: SurfaceConfig,
    notify: @escaping @Sendable () -> Void
  ) {
    slots[id] = SurfaceSlot(
      id: id, material: material, scroll: scroll, config: config, notify: notify)
  }

  /// 面が閉じた。刻みを外し、組版のキャッシュと写しの最後の参照をここ（描画スレッド）で手放す。
  func detach(_ id: Int) {
    guard let slot = slots.removeValue(forKey: id) else { return }
    slot.blinkTimer.map { CFRunLoopTimerInvalidate($0) }
    slot.clock?.invalidate()
    slot.recorder.flush()
    slot.recorder.flushTyping()
    _ = slot.material.clear()
  }

  func bind(_ id: Int, target: FrameTarget, clock: FrameClock) {
    guard let slot = slots[id] else {
      clock.invalidate()
      return
    }
    slot.clock?.invalidate()
    slot.target = target
    slot.clock = clock
    clock.isPaused = false
  }

  /// 箱に何かが書かれた（または点滅が切り替わる）。止めていた刻みを再開し、次に画面に出る刻みまでに描き終えられるなら、
  /// 刻みを待たずにその場で 1 コマ描く（止まっていた面の最初の変化が、次の刻みまでの待ちのぶん遅れない）。刻みが走っている
  /// 間は次の刻みに任せる。
  func wake(_ id: Int) {
    guard let slot = slots[id] else { return }
    slot.blinkTimer.map { CFRunLoopTimerInvalidate($0) }
    slot.blinkTimer = nil
    slot.idleTicks = 0
    guard let clock = slot.clock, clock.isPaused else { return }
    clock.isPaused = false
    let now = CACurrentMediaTime()
    let target = clock.nextTarget(after: now)
    guard target - now > Self.wakeBudget else { return }
    tick(id, target: target)
  }

  func slot(_ id: Int) -> SurfaceSlot? { slots[id] }

  private func pipelinesDidBecomeReady() {
    for id in slots.keys { wake(id) }
  }

  private struct AtlasKey: Hashable {
    var scale: CGFloat
    var space: CGColorSpace
  }

  func atlas(scale: CGFloat, space: CGColorSpace) -> GlyphAtlas {
    let key = AtlasKey(scale: scale, space: space)
    if let atlas = atlases[key] { return atlas }
    let atlas = GlyphAtlas(device: device, scale: scale, space: space, fonts: fonts)
    atlases[key] = atlas
    return atlas
  }

  // MARK: - 1 コマ

  /// 刻みごとに呼ばれる。`target` はこのコマが画面に出る予定の時刻。
  func tick(_ id: Int, target: Double) {
    guard let slot = slots[id], let clock = slot.clock, let frameTarget = slot.target else {
      return
    }
    guard let pipelines = gate.ready else {
      pause(slot, clock, blinking: nil)
      return
    }
    // 刻みの長さは最初の呼び出しまで分からず、画面を移れば変わる。
    slot.recorder.period = clock.period
    adoptFramePeriod()
    let material = slot.material.take()
    slot.lines.receive(material.rowEdits)
    slot.keystrokes += material.keystrokes
    guard material.visible, material.content != nil, material.palette != nil,
      material.size.width > 0, material.size.height > 0
    else {
      pause(slot, clock, blinking: nil)
      return
    }
    let caretVisible = material.caret.caretVisible(at: target)
    let moved =
      material.revision != slot.drawnMaterial || slot.scroll.revision != slot.drawnScroll
      || slot.returning || slot.atlasDirty
    guard moved || caretVisible != slot.drawnCaretVisible else {
      slot.recorder.idle(at: CACurrentMediaTime())
      slot.idleTicks += 1
      if slot.idleTicks >= Self.idleTicksBeforePause {
        pause(slot, clock, blinking: material.caret)
      }
      return
    }
    slot.idleTicks = 0
    let atlas = atlas(scale: material.scale, space: material.space)
    if atlas.isFull, gpuInflight == 0 { atlas.reset() }
    guard slot.unpresented < frameTarget.limit, gpuInflight < Self.gpuLimit, !atlas.isFull,
      let acquired = frameTarget.acquire()
    else {
      slot.owed = true
      slot.recorder.skipped()
      return
    }
    draw(slot, material, into: acquired, at: target, Pass(pipelines: pipelines, atlas: atlas))
    if !moved { pause(slot, clock, blinking: material.caret) }
  }

  /// 描くと決めたコマを組み立てて出す。
  private func draw(
    _ slot: SurfaceSlot, _ material: FrameMaterial, into acquired: AcquiredFrame, at target: Double,
    _ pass: Pass
  ) {
    let began = CACurrentMediaTime()
    let caretVisible = material.caret.caretVisible(at: target)
    let frame = slot.scroll.frame(at: target, material: material.revision)
    let texture = acquired.texture
    slot.builder.build(
      FrameBuilder.Source(
        material: material, position: frame.position, caretVisible: caretVisible,
        pixels: (texture.width, texture.height), atlas: pass.atlas, config: slot.config),
      cache: slot.lines, fonts: fonts)
    let widened = slot.scroll.measured(
      longestLine: slot.builder.longestLine, version: material.content?.version)
    guard let commands = queue.makeCommandBuffer(),
      let bufferIndex = encode(slot.builder, into: texture, pass, commands)
    else {
      slot.owed = true
      return
    }
    frameCounter += 1
    let frameID = frameCounter
    let id = slot.id
    slot.unpresented += 1
    let moving = slot.drawnPosition != frame.position
    let wasReturning = slot.returning
    slot.drawnMaterial = material.revision
    slot.drawnScroll = frame.revision
    slot.drawnCaretVisible = caretVisible
    let keystrokes = slot.keystrokes
    slot.keystrokes.removeAll(keepingCapacity: true)
    slot.drawnPosition = frame.position
    slot.returning = frame.returning
    slot.atlasDirty = pass.atlas.isFull
    commands.addCompletedHandler { _ in
      RenderThread.shared.perform { $0.commandsDidComplete(bufferIndex) }
    }
    acquired.present(commands) { time in
      RenderThread.shared.perform { $0.presented(id, frame: frameID, time: time) }
    }
    commands.commit()
    let committed = CACurrentMediaTime()
    let pixels = Self.pixelSize(material)
    slot.recorder.drew(
      FrameRecorder.Drawn(
        frame: frameID, target: target, cpu: committed - began,
        shaped: slot.lines.shapedInFrame > 0, committed: committed, events: frame.events,
        keystrokes: keystrokes, moving: moving, gesture: frame.gesture,
        mismatch: texture.width != pixels.width || texture.height != pixels.height))
    if frame.returning || wasReturning || widened { slot.notify() }
    if let last = keystrokes.max() { scheduleTypingFlush(slot.id, after: last) }
  }

  /// 打鍵の塊の区切りの長さだけ次の打鍵が無ければ、塊を締める。
  private func scheduleTypingFlush(_ id: Int, after keystroke: Double) {
    DispatchQueue.global().asyncAfter(deadline: .now() + FrameRecorder.burstGap + 0.1) {
      RenderThread.shared.perform { renderer in
        guard let slot = renderer.slot(id), slot.recorder.lastKeystroke == keystroke else { return }
        slot.recorder.flushTyping()
      }
    }
  }

  var gpuInflight: Int { buffers.filter(\.busy).count }

  /// 描画スレッドの時間制約を、結ばれた面の最も短い刻みに合わせる（変わったときだけ申告し直す）。
  private func adoptFramePeriod() {
    guard let period = slots.values.compactMap({ $0.clock?.period }).min(), period != framePeriod
    else { return }
    framePeriod = period
    RenderThread.adopt(framePeriod: period)
  }

  /// 刻みを止める。`blinking` のキャレットが点滅していれば、次に表示が切り替わる時刻に起きるタイマーを置く。
  private func pause(_ slot: SurfaceSlot, _ clock: FrameClock, blinking caret: CaretMaterial?) {
    if slot.blinkTimer == nil, let next = caret?.nextBlink(after: CACurrentMediaTime()) {
      let id = slot.id
      let fire = CFAbsoluteTimeGetCurrent() + max(0, next - CACurrentMediaTime())
      let timer = CFRunLoopTimerCreateWithHandler(nil, fire, 0, 0, 0) { _ in
        RenderThread.shared.onThread { $0.wake(id) }
      }
      CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
      slot.blinkTimer = timer
    }
    guard !clock.isPaused else { return }
    clock.isPaused = true
    guard slot.recorder.gesture != nil else { return }
    let id = slot.id
    let drawn = slot.recorder.drawnCount
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.gestureSettle) {
      RenderThread.shared.perform { $0.flushGesture(id, ifNothingDrawnSince: drawn) }
    }
  }

  /// 止めてから次のコマを描いていなければ、ジェスチャーを締める（main が詰まって刻みが止まっただけなら締めない）。
  private func flushGesture(_ id: Int, ifNothingDrawnSince drawn: Int) {
    guard let slot = slots[id], slot.recorder.drawnCount == drawn else { return }
    slot.recorder.flush()
  }

  /// コマが画面に出た（捨てられた）。飛ばしたコマがあれば、次の刻みを待たずに描く。
  private func presented(_ id: Int, frame: Int, time: Double?) {
    guard let slot = slots[id] else { return }
    slot.unpresented -= 1
    slot.recorder.presented(frame: frame, time: time)
    guard slot.owed, let clock = slot.clock else { return }
    slot.owed = false
    tick(id, target: clock.nextTarget(after: CACurrentMediaTime()))
  }

  private func commandsDidComplete(_ index: Int) {
    buffers[index].busy = false
  }

  static func pixelSize(_ material: FrameMaterial) -> (width: Int, height: Int) {
    (
      Int((material.size.width * material.scale).rounded()),
      Int((material.size.height * material.scale).rounded())
    )
  }

}

/// 面 1 つぶんの描画スレッドの持ち物。
final class SurfaceSlot {
  let id: Int
  let material: MaterialBox
  let scroll: ScrollBox
  let config: SurfaceConfig
  /// 描画スレッドだけが変える位置と範囲（端への戻り・組んだ行で伸びた横の範囲）が変わったことを main へ知らせる
  /// （非同期）。
  let notify: @Sendable () -> Void
  var target: FrameTarget?
  var clock: FrameClock?
  let lines = LineLayoutCache()
  let builder = FrameBuilder()
  let recorder = FrameRecorder()
  /// 出したコマのうち、まだ画面に出ていない（present も破棄もされていない）数。
  var unpresented = 0
  /// 上限で飛ばしたコマがある（画面に出たら次の刻みを待たずに描く）。
  var owed = false
  var idleTicks = 0
  /// 最後に描いたコマの材料・スクロールの版と位置。
  var drawnMaterial = -1
  var drawnScroll = -1
  var drawnPosition: SIMD2<Double>?
  var returning = false
  var drawnCaretVisible = false
  /// アトラスが埋まって字を落としたコマを描いた（作り直してもう一度描く）。
  var atlasDirty = false
  /// 読んだ材料に入っていて、まだ描いていない打鍵の時刻。
  var keystrokes: [Double] = []
  /// 次に点滅が切り替わる時刻に起きるタイマー（止めている間だけ）。
  var blinkTimer: CFRunLoopTimer?

  init(
    id: Int, material: MaterialBox, scroll: ScrollBox, config: SurfaceConfig,
    notify: @escaping @Sendable () -> Void
  ) {
    self.id = id
    self.material = material
    self.scroll = scroll
    self.config = config
    self.notify = notify
  }
}
