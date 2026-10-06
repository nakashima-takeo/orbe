import AppKit
import Metal
import OrbeEditorCore
import QuartzCore
import os

/// 1 コマを組み立てて Metal へ符号化し、画面（または画面外）へ出す。描画スレッドだけが触る。
///
/// キャレットの点滅は時刻から決める。描くものが変わらなければ刻みを止め、焦点のある面は、次に表示が切り替わった後の最初の
/// 刻みの半刻み前にだけ run loop のタイマーで自分を起こし、その場でその刻みへ描いてすぐ止める（点滅 1 回で 1 回だけ起きる）。
///
/// どの面のためにも待たない——面ごとに「画面に出ていないコマ」を数え、上限の面はそのコマを飛ばす（`nextDrawable` は
/// 実際には待たない）。GPU の空きも待たずに数える。飛ばしたコマは、画面に出た知らせを受けた時点で次の刻みを待たずに描く。
/// 位置は描く直前にコマの予定時刻で読む（指の出来事をできるだけ新しく入れる）。描くものが変わらないコマが続いたら、
/// その面の刻みを止め、箱に書かれて起こされたら、その場で 1 コマ描いてから刻みに戻る。コマを出した後、ミニマップが
/// 動いていれば次のコマが要りそうなまとまりを作っておく（`MinimapCells.prefetch`）。
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
    id: Int, boxes: SurfaceBoxes, config: SurfaceConfig, notify: @escaping @Sendable () -> Void
  ) {
    slots[id] = SurfaceSlot(id: id, boxes: boxes, config: config, notify: notify)
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
      pause(slot, clock)
      return
    }
    // 刻みの長さは最初の呼び出しまで分からず、画面を移れば変わる。
    slot.recorder.period = clock.period
    adoptFramePeriod()
    let material = slot.material.take()
    slot.receive(material)
    guard material.visible, material.content != nil, material.palette != nil,
      material.size.width > 0, material.size.height > 0
    else {
      pause(slot, clock)
      return
    }
    let caretVisible = material.caret.caretVisible(at: target)
    let changed =
      material.revision != slot.drawnMaterial || slot.scroll.revision != slot.drawnScroll
      || slot.returning || slot.atlasDirty || slot.motion.due(at: target)
    guard changed || caretVisible != slot.drawnCaretVisible else {
      slot.recorder.idle(at: CACurrentMediaTime())
      slot.idleTicks += 1
      if slot.idleTicks >= Self.idleTicksBeforePause {
        pause(slot, clock, blinking: material.caret, after: target, fading: slot.motion.wakeAt)
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
    if !changed {
      pause(slot, clock, blinking: material.caret, after: target, fading: slot.motion.wakeAt)
    }
  }

  /// 描くと決めたコマを組み立てて出す。
  private func draw(
    _ slot: SurfaceSlot, _ material: FrameMaterial, into acquired: AcquiredFrame, at target: Double,
    _ pass: Pass
  ) {
    let began = CACurrentMediaTime()
    let caretVisible = material.caret.caretVisible(at: target)
    let revealed = begin(slot, material)
    let frame = slot.scroll.frame(
      at: target, period: slot.clock?.period ?? 1.0 / 120, material: material.revision)
    let texture = acquired.texture
    slot.build(
      material, scroll: (frame.position, frame.limits), moment: (caretVisible, target),
      target: ((texture.width, texture.height), pass.atlas), fonts: fonts)
    let widened = slot.scroll.measured(
      longestLine: slot.builder.longestLine, version: material.content?.version)
    guard let commands = queue.makeCommandBuffer(),
      let bufferIndex = encode(
        slot.builder, into: texture, minimapPass(slot, material, pass), commands)
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
    if frame.returning || wasReturning || widened || revealed { slot.notify() }
    if let last = keystrokes.max() { scheduleTypingFlush(slot.id, after: last) }
    slot.prefetchMinimap(material)
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

  /// コマを組み始める。取引が頼んだ横の「見えるところまで」がまだなら、区間の行を組んで x を引き、横の位置を寄せる（位置か
  /// 範囲が変わったら true）。区間の行はこのコマで描く行なので、組んだ結果はそのまま描くのに使う。
  func begin(_ slot: SurfaceSlot, _ material: FrameMaterial) -> Bool {
    guard let content = material.content else { return false }
    slot.lines.beginFrame(version: content.version, tabColumns: material.tabColumns)
    guard let reveal = material.reveal, reveal.serial != slot.revealed else { return false }
    slot.revealed = reveal.serial
    let text = content.text
    let location = min(max(0, reveal.range.location), text.length)
    let end = min(max(location, NSMaxRange(reveal.range)), text.length)
    let row = text.row(containing: location)
    let start = text.lineStart(row)
    let line = slot.lines.line(
      row: row, source: { LineShaper.source(row: row, in: text).source },
      tabColumns: material.tabColumns, config: slot.config, fonts: fonts, carets: true)
    guard let carets = line.carets else { return false }
    let x0 = Double(carets.x(location - start))
    let x1 = text.row(containing: end) == row ? Double(carets.x(end - start)) : x0
    return slot.scroll.reveal(min(x0, x1)...max(x0, x1), lineWidth: Double(line.width))
  }

  var gpuInflight: Int { buffers.filter(\.busy).count }

  /// 描画スレッドの時間制約を、結ばれた面の最も短い刻みに合わせる（変わったときだけ申告し直す）。
  private func adoptFramePeriod() {
    guard let period = slots.values.compactMap({ $0.clock?.period }).min(), period != framePeriod
    else { return }
    framePeriod = period
    RenderThread.adopt(framePeriod: period)
  }

  /// 刻みを止める。`blinking` のキャレットが点滅していれば `drawn`（最後に描いた、または描かないと決めたコマの予定時刻）の
  /// 後で表示が切り替わる時刻と、`fading`（つまみが消え始める時刻）の早い方から最初の刻みの、半刻み前に起きるタイマーを
  /// 置く——起きたその場で、その刻みへ切り替わった表示を描ける（刻みを再開して、タイマーと刻みの 2 回起きることがない）。
  /// 両方を渡すのは見えていて描き終えた面だけ（`fading` はコマを組むときにしか進まないので、描かない面へ渡すと過ぎた
  /// 時刻で起き続ける）。
  private func pause(
    _ slot: SurfaceSlot, _ clock: FrameClock, blinking caret: CaretMaterial? = nil,
    after drawn: Double = 0, fading: Double? = nil
  ) {
    let blink = caret?.nextBlink(after: drawn)
    let next = [blink, fading].compactMap { $0 }.min()
    if slot.blinkTimer == nil, let next {
      let id = slot.id
      let wake = clock.nextTarget(after: next) - clock.period / 2
      let fire = CFAbsoluteTimeGetCurrent() + max(0, wake - CACurrentMediaTime())
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
