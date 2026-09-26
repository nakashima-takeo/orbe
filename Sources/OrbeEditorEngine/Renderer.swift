import AppKit
import Metal
import QuartzCore

/// 1 コマを組み立てて Metal へ符号化し、画面（または画面外）へ出す。描画スレッドだけが触る。
///
/// どの面のためにも待たない——面ごとに「画面に出ていないコマ」を数え、上限の面はそのコマを飛ばす（`nextDrawable` は
/// 実際には待たない）。GPU の空きも待たずに数える。飛ばしたコマは、画面に出た知らせを受けた時点で次の刻みを待たずに描く。
/// 位置は描く直前にコマの予定時刻で読む（指の出来事をできるだけ新しく入れる）。描くものが変わらないコマが続いたら、
/// その面の刻みを止める。
final class Renderer {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let gate: PipelineGate
  let fonts = FontRegistry()
  private var atlases: [CGFloat: GlyphAtlas] = [:]
  private var slots: [Int: SurfaceSlot] = [:]
  /// 命令の列ごとの instance の buffer（使用中の印つき）。使用中の数が GPU に出して終わっていない命令の列の数。
  var buffers: [(buffer: MTLBuffer, busy: Bool)] = []
  private var frameCounter = 0
  /// GPU に出して終わっていない命令の列の上限。
  static let gpuLimit = 3
  /// 描くものが変わらないコマがこれだけ続いたら刻みを止める。
  static let idleTicksBeforePause = 2
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
    slot.clock?.invalidate()
    slot.recorder.flush()
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
    slot.recorder.period = clock.period
    clock.isPaused = false
  }

  /// 箱に何かが書かれた。止めていた刻みを再開する。
  func wake(_ id: Int) {
    guard let slot = slots[id] else { return }
    slot.idleTicks = 0
    slot.clock?.isPaused = false
  }

  func slot(_ id: Int) -> SurfaceSlot? { slots[id] }

  private func pipelinesDidBecomeReady() {
    for id in slots.keys { wake(id) }
  }

  func atlas(scale: CGFloat) -> GlyphAtlas {
    if let atlas = atlases[scale] { return atlas }
    let atlas = GlyphAtlas(device: device, scale: scale, fonts: fonts)
    atlases[scale] = atlas
    return atlas
  }

  // MARK: - 1 コマ

  /// 刻みごとに呼ばれる。`target` はこのコマが画面に出る予定の時刻。
  func tick(_ id: Int, target: Double) {
    guard let slot = slots[id], let clock = slot.clock, let frameTarget = slot.target,
      let pipelines = gate.ready
    else { return }
    let material = slot.material.read()
    guard material.visible, material.content != nil, material.palette != nil,
      material.size.width > 0, material.size.height > 0
    else {
      pause(slot, clock)
      return
    }
    let changed =
      material.revision != slot.drawnMaterial || slot.scroll.revision != slot.drawnScroll
      || slot.returning || slot.atlasDirty
    guard changed else {
      slot.idleTicks += 1
      if slot.idleTicks >= Self.idleTicksBeforePause { pause(slot, clock) }
      return
    }
    slot.idleTicks = 0
    let atlas = atlas(scale: material.scale)
    if atlas.isFull, gpuInflight == 0 { atlas.reset() }
    guard slot.unpresented < frameTarget.limit, gpuInflight < Self.gpuLimit, !atlas.isFull,
      let acquired = frameTarget.acquire()
    else {
      slot.owed = true
      slot.recorder.skipped()
      return
    }
    draw(slot, material, into: acquired, at: target, Pass(pipelines: pipelines, atlas: atlas))
  }

  /// 描くと決めたコマを組み立てて出す。
  private func draw(
    _ slot: SurfaceSlot, _ material: FrameMaterial, into acquired: AcquiredFrame, at target: Double,
    _ pass: Pass
  ) {
    let began = CACurrentMediaTime()
    let frame = slot.scroll.frame(at: target)
    let texture = acquired.texture
    slot.builder.build(
      FrameBuilder.Source(
        material: material, position: frame.position, pixels: (texture.width, texture.height),
        atlas: pass.atlas, config: slot.config), cache: slot.lines, fonts: fonts)
    if slot.builder.longestLine > 0 { slot.scroll.noteLine(width: slot.builder.longestLine) }
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
    let moving =
      slot.drawnPosition.map { !Self.samePixel($0, frame.position, material.scale) } ?? true
    let wasReturning = slot.returning
    slot.drawnMaterial = material.revision
    slot.drawnScroll = frame.revision
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
        frame: frameID, target: target, cpu: committed - began, committed: committed,
        events: frame.events,
        moving: moving, gesture: frame.gesture,
        mismatch: texture.width != pixels.width || texture.height != pixels.height))
    if frame.returning || wasReturning { slot.notify() }
  }

  var gpuInflight: Int { buffers.filter(\.busy).count }

  private func pause(_ slot: SurfaceSlot, _ clock: FrameClock) {
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

  private static func samePixel(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ scale: CGFloat) -> Bool {
    let s = Double(scale)
    return (a * s).rounded(.toNearestOrAwayFromZero) == (b * s).rounded(.toNearestOrAwayFromZero)
  }
}

/// 面 1 つぶんの描画スレッドの持ち物。
final class SurfaceSlot {
  let id: Int
  let material: MaterialBox
  let scroll: ScrollBox
  let config: SurfaceConfig
  /// 描画スレッドだけが進める動き（端への戻り）で位置が変わったことを main へ知らせる（非同期）。
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
  /// アトラスが埋まって字を落としたコマを描いた（作り直してもう一度描く）。
  var atlasDirty = false

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
