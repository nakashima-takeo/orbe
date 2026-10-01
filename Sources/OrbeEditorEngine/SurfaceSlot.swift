import AppKit
import Metal
import OrbeEditorCore
import os

/// 面 1 つぶんの描画スレッドの持ち物。
final class SurfaceSlot {
  let id: Int
  let material: MaterialBox
  let scroll: ScrollBox
  /// 最後に描いたミニマップの配置（main が押下を解く）。
  let placement: MinimapPlacementBox
  let config: SurfaceConfig
  /// 描画スレッドだけが変える位置と範囲（端への戻り・組んだ行で伸びた横の範囲）が変わったことを main へ知らせる
  /// （非同期）。
  let notify: @Sendable () -> Void
  var target: FrameTarget?
  var clock: FrameClock?
  let lines = LineLayoutCache()
  let minimapCells = MinimapCells()
  let rulerRows = RulerRows()
  let motion = OverviewMotion()
  /// 最後に描いたミニマップの配置（次のコマの揺れ止め）と、その前のコマからミニマップの描き始めの行が動いた数。
  var minimapPlacement: MinimapLayout?
  private var minimapMotion = 0
  /// ミニマップの字形の表（倍率ごと）と、装飾を組として描く画面外の 1 枚。
  var minimapSheet: (scale: Int, texture: MTLTexture)?
  var minimapLayer: MTLTexture?
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
  /// 次に点滅が切り替わる時刻か、つまみが消え始める時刻の早い方に起きるタイマー（止めている間だけ）。
  var blinkTimer: CFRunLoopTimer?
  /// 解いた横の「見えるところまで」の通し番号。
  var revealed = 0

  init(
    id: Int, boxes: SurfaceBoxes, config: SurfaceConfig,
    notify: @escaping @Sendable () -> Void
  ) {
    self.id = id
    material = boxes.material
    scroll = boxes.scroll
    placement = boxes.placement
    self.config = config
    self.notify = notify
  }

  /// 引き取った材料の、まだ受け取っていない変わった行と打鍵を受け取る。
  func receive(_ material: FrameMaterial) {
    lines.receive(material.rowEdits)
    minimapCells.receive(material.rowEdits)
    rulerRows.receive(material.rowEdits)
    keystrokes += material.keystrokes
  }

  /// 1 コマを組み、描いたミニマップの配置を覚えて main へ渡す。`scroll` はこのコマの位置とその範囲、`moment` はこのコマで
  /// キャレットを描くかとコマの時刻、`target` は描く先の
  /// 大きさ（px）とアトラス。
  func build(
    _ material: FrameMaterial, scroll: (position: SIMD2<Double>, limits: ScrollPhysics.Limits),
    moment: (caretVisible: Bool, time: Double),
    target: (pixels: (width: Int, height: Int), atlas: GlyphAtlas), fonts: FontRegistry
  ) {
    builder.build(
      FrameBuilder.Source(
        material: material, position: scroll.position, limits: scroll.limits,
        caretVisible: moment.caretVisible, pixels: target.pixels, atlas: target.atlas,
        config: config,
        minimapCells: minimapCells, rulerRows: rulerRows, motion: motion, time: moment.time,
        baselines: self.scroll.baselines, previousPlacement: minimapPlacement),
      cache: lines, fonts: fonts)
    if let previous = minimapPlacement, let placement = builder.minimap.placement {
      minimapMotion = placement.startLine - previous.startLine
    }
    minimapPlacement = builder.minimap.placement
    placement.write(builder.minimap.placement)
  }
}

extension SurfaceSlot {
  /// コマを出した後で、ミニマップが動いた向きに、次のコマが要りそうなチャンクを先に作る（→
  /// `MinimapCells.prefetch`）。
  func prefetchMinimap(_ material: FrameMaterial) {
    guard minimapMotion != 0, let content = material.content, let placement = minimapPlacement
    else { return }
    minimapCells.prefetch(
      placement.lines, motion: minimapMotion, text: content.text, roles: content.roles)
  }
}

/// main と描画スレッドの間の、面ごとの箱——描く材料・スクロールの状態・最後に描いたミニマップの配置。
struct SurfaceBoxes: Sendable {
  let material: MaterialBox
  let scroll: ScrollBox
  let placement: MinimapPlacementBox
}

/// 最後に描いたミニマップの配置（描画スレッド → main）。配置は揺れ止めの前回の配置に依るので、main はミニマップの押下と
/// 帯のドラッグの起点を、描いたとおりのこの配置で解く（待たない。VS Code も最後に描いた配置で解く）。
final class MinimapPlacementBox: Sendable {
  private let state = OSAllocatedUnfairLock<MinimapLayout?>(initialState: nil)

  func write(_ placement: MinimapLayout?) { state.withLock { $0 = placement } }

  func read() -> MinimapLayout? { state.withLock { $0 } }
}
