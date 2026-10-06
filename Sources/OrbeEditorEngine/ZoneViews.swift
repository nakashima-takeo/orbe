import AppKit
import OrbeEditorCore
import QuartzCore

/// 区画の view の置き場（main）。区画のある面だけが持つ。
///
/// 区画の view は面の view の子の入れ物に載る。入れ物は本文の区画（行番号の列の右から右列の左まで、上端の余白の下）で切り
/// 取り、横スクロールバーが出ている間はその帯を除く——区画は横スクロールバーと上端の影を覆わない。上端の影は、区画のある
/// 面では入れ物の上の view が描く（本文の Metal の層は子の view の下にあるので、Metal の影は区画の下になる）。重ね順は下から
/// 本文の層 → 入れ物 → 影 → 俯瞰の当たりの view。
///
/// 高さは、view に本文の区画の幅を与えて（frame の幅と幅の制約）測った fitting size の高さ。幅が変わったとき・載せる側が
/// 測り直すと言ったときに測り直す。
///
/// 位置は、main の display link の刻みごとに、スクロールの箱がその刻みに封じた縦の位置と main の縦の並びで置く——描画
/// スレッドの同じ刻みのコマと同じ位置。動かすのは見えている区画だけで、他は隠す。刻みは位置が動きうる間（出す 1 か所・
/// 指の出来事・描画スレッドの戻り）だけ回し、版が動かず戻りの途中でない刻みが続けば止める。main が詰まっている間は区画の
/// view だけが遅れる（本文のコマは落ちない）。
@MainActor
final class ZoneViews {
  private unowned let surface: MetalTextSurface
  private let container = ZoneContainerView()
  private let shadow: ZoneShadowView
  /// 置いている区画の view と、測った高さ。
  private var views: [ObjectIdentifier: NSView] = [:]
  private var heights: [ObjectIdentifier: Double] = [:]
  /// 測った幅。
  private var width: CGFloat?
  /// 見せている区画。
  private var shown: Set<ObjectIdentifier> = []
  private var link: CADisplayLink?
  private var lastRevision = -1
  private var stillTicks = 0

  /// 版が動かず戻りの途中でない刻みがこれだけ続いたら止める。
  private static let ticksBeforePause = 2

  init(surface: MetalTextSurface, shadowColor: NSColor) {
    self.surface = surface
    shadow = ZoneShadowView(color: shadowColor)
    let view = surface.textView
    view.addSubview(container, positioned: .below, relativeTo: view.overviewHits)
    view.addSubview(shadow, positioned: .below, relativeTo: view.overviewHits)
    surface.scroll.setSealing(true)
  }

  /// 面から外す（区画が無くなった）。
  func detach() {
    stopTicking()
    for view in views.values { view.removeFromSuperview() }
    container.removeFromSuperview()
    shadow.removeFromSuperview()
    surface.scroll.setSealing(false)
  }

  /// 置く view を `list` にする。足した view は入れ物に載せて幅 `width` で測り、外れた view は外す。
  func sync(_ list: [NSView], width: CGFloat) {
    let ids = Set(list.map(ObjectIdentifier.init))
    for (id, view) in views where !ids.contains(id) {
      view.removeFromSuperview()
      views[id] = nil
      heights[id] = nil
      shown.remove(id)
    }
    for view in list where views[ObjectIdentifier(view)] == nil {
      let id = ObjectIdentifier(view)
      views[id] = view
      view.isHidden = true
      container.addSubview(view)
      heights[id] = measure(view, width: width)
    }
    self.width = width
  }

  /// 区画 `id` の高さ（pt）。
  func height(of id: ObjectIdentifier) -> Double { heights[id] ?? 0 }

  /// 幅 `width` が測った幅と違えば全部を測り直す。高さが変わったら true。
  func fit(width: CGFloat) -> Bool {
    guard width != self.width else { return false }
    self.width = width
    var changed = false
    for (id, view) in views {
      let height = measure(view, width: width)
      if height != heights[id] { changed = true }
      heights[id] = height
    }
    return changed
  }

  /// `view` を今の幅で測り直す。置いていない view なら nil、置いていれば高さが変わったか。
  func remeasure(_ view: NSView) -> Bool? {
    let id = ObjectIdentifier(view)
    guard views[id] != nil, let width else { return nil }
    let height = measure(view, width: width)
    guard height != heights[id] else { return false }
    heights[id] = height
    return true
  }

  private func measure(_ view: NSView, width: CGFloat) -> Double {
    view.setFrameSize(NSSize(width: width, height: view.frame.height))
    let constraint = view.widthAnchor.constraint(equalToConstant: width)
    constraint.isActive = true
    defer { constraint.isActive = false }
    return Double(view.fittingSize.height)
  }

  // MARK: - 置く

  /// main の今の位置で置く（出す 1 か所の終わり——並びや位置を置き直した周のうちに置く）。
  func placeViews() {
    let (position, limits) = surface.scrollState()
    place(position, limits)
    startTicking()
  }

  /// 位置 `position`（範囲 `limits`）で入れ物・影・見えている区画を置く。
  private func place(_ position: SIMD2<Double>, _ limits: ScrollPhysics.Limits) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let config = surface.config
    let layout = surface.surfaceLayout
    let text = layout.text
    let bottom =
      limits.maximum.x > 0 ? layout.horizontalScrollbar.minY : layout.size.height
    let frame = NSRect(
      x: text.minX, y: config.topInset, width: text.width,
      height: max(0, bottom - config.topInset))
    if container.frame != frame { container.frame = frame }
    let shadowFrame = NSRect(x: 0, y: 0, width: text.maxX, height: ZoneShadowView.depth)
    if shadow.frame != shadowFrame { shadow.frame = shadowFrame }
    shadow.isHidden = !(limits.clampedY(position) > 0)
    let rows = surface.rows
    var visible = Set<ObjectIdentifier>()
    for index in rows.blocks(from: position.y, to: position.y + Double(frame.height)) {
      guard case .zone(let id) = rows.contents[index], let view = views[id] else { continue }
      visible.insert(id)
      let zone = NSRect(
        x: 0, y: rows.top(ofBlock: index) - position.y, width: frame.width,
        height: rows.heights[index])
      if view.frame != zone { view.frame = zone }
      if view.isHidden { view.isHidden = false }
    }
    for id in shown.subtracting(visible) { views[id]?.isHidden = true }
    shown = visible
  }

  // MARK: - 刻み

  /// 位置が動きうる——刻みを回す（回っていればそのまま）。
  func startTicking() {
    stillTicks = 0
    guard link == nil else { return }
    let link = surface.textView.displayLink(
      target: ZoneTicker(self), selector: #selector(ZoneTicker.step(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  private func stopTicking() {
    link?.invalidate()
    link = nil
  }

  /// 刻み 1 つ——描画スレッドが同じ刻みのコマで描く位置で置く。
  fileprivate func step(_ link: CADisplayLink) {
    let period = link.duration > 0 ? link.duration : 1.0 / 120
    let frame = surface.scroll.sealed(at: link.targetTimestamp, period: period)
    place(frame.position, frame.limits)
    if frame.revision == lastRevision, !frame.returning {
      stillTicks += 1
      if stillTicks >= Self.ticksBeforePause { stopTicking() }
    } else {
      stillTicks = 0
    }
    lastRevision = frame.revision
  }
}

/// display link の呼び出し口（区画の置き場を弱く持つ——display link は呼び出し口を強く持つ）。置き場が無くなって
/// いれば（面が閉じた）、刻みを外す。
private final class ZoneTicker: NSObject {
  weak var zones: ZoneViews?

  init(_ zones: ZoneViews) {
    self.zones = zones
  }

  @MainActor @objc func step(_ link: CADisplayLink) {
    guard let zones else { return link.invalidate() }
    zones.step(link)
  }
}

/// 区画の view の入れ物。自分の点では当たらない（区画の view が受けない点は面へ落ちる）。
final class ZoneContainerView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    clipsToBounds = true
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

/// 区画のある面の上端の影——Metal の影と同じ色・同じ濃さの規則（`FrameBuilder.shadowStrength`）で、装置の画素の行ごとに
/// 塗る。当たらない。
final class ZoneShadowView: NSView {
  /// 影の深さ（pt）。
  static let depth: CGFloat = 6

  private let color: NSColor

  init(color: NSColor) {
    self.color = color
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let scale = window?.backingScaleFactor ?? 2
    let rows = Int((Double(Self.depth) * scale).rounded())
    let resolved = color.usingColorSpace(.sRGB) ?? color
    for y in 0..<rows {
      let strength = FrameBuilder.shadowStrength(
        (Double(y) + 0.5) / scale, length: Double(Self.depth))
      resolved.withAlphaComponent(resolved.alphaComponent * strength).setFill()
      NSRect(x: 0, y: CGFloat(y) / scale, width: bounds.width, height: 1 / scale).fill()
    }
  }
}
