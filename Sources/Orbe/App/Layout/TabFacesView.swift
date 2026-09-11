import AppKit

/// タブの器: [エディター面 | 背 | 端末面]。配置（`FaceLayout`）を幅で解いた結果を子の frame に写すだけで、
/// 配置の正はタブが持つ。面は clip の器で、中身の幅は面の幅に等しい。
///
/// 隠れた端末の中身は最後に見えていた寸法のまま据え置く（隠すたびの pty resize と scrollback の
/// 再折り返しを避ける）。隠れたまま生まれた端末は「戻したときに得る寸法」で起きる。
/// 遷移は「中身のサイズは遷移開始時に 1 回・面の clip と中身の位置だけ動く」。背のドラッグ中は
/// 面と背をポインタごとに置き、中身の resize は表示のフレーム単位に間引く。
final class TabFacesView: NSView {
  let terminal: SurfaceScrollView
  let editor: EditorPaneView
  let spine = SpineView()
  private let editorFace = FaceClipView()
  private let terminalFace = FaceClipView()

  /// タブが `set` で写す配置の鏡。ドラッグ中は書き換えない。
  private(set) var faces: FaceLayout
  /// 今見えている配置を器の幅で解いた結果（ドラッグ中はポインタの値）。
  private(set) var resolved: FaceGeometry.Resolved
  var projection: FaceGeometry.Projection { resolved.projection }
  /// 投影（ドット・背の見え方・分割中か）が変わった。器の幅で変わりうるので chrome はここから追従する。
  var onProjectionChange: (() -> Void)?
  /// 背のクリック／離したときに求める配置。タブが正規化して状態に置き、`set` で戻す。
  var onFacesRequested: ((FaceLayout, _ animated: Bool) -> Void)?

  /// 焦点の面の responder。
  var focusTarget: NSView { faces.focus == .editor ? editor : terminal.surfaceView }

  private var lastVisibleTerminalSize: CGSize?
  private var reportedProjection: FaceGeometry.Projection?
  /// 今置いてあるエディター幅（遷移の起点）。
  private var placedEditorWidth: CGFloat = 0
  private var dragOrigin: FaceGeometry.Resolved?
  /// ドラッグ中、次のフレームで中身へ配る寸法の元。
  private var pendingDragSizes: FaceGeometry.Resolved?
  private var clock: FrameClock?

  override var isFlipped: Bool { true }

  init(terminal: SurfaceScrollView, editor: EditorPaneView, faces: FaceLayout) {
    self.terminal = terminal
    self.editor = editor
    self.faces = faces
    resolved = FaceGeometry.resolve(faces, width: 0)
    super.init(frame: .zero)
    for view in [editorFace, spine, terminalFace] {
      view.autoresizingMask = []
      addSubview(view)
    }
    editor.autoresizingMask = []
    terminal.autoresizingMask = []
    editorFace.addSubview(editor)
    terminalFace.addSubview(terminal)
    spine.onGrab = { [unowned self] in
      dragOrigin = resolved
      window?.makeFirstResponder(focusTarget)
    }
    spine.onDrag = { [unowned self] x in drag(to: x) }
    spine.onRelease = { [unowned self] in release() }
    spine.onClick = { [unowned self] in
      dragOrigin = nil
      onFacesRequested?(FaceGeometry.spineClick(faces, resolved), true)
    }
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  deinit { clock?.cancel() }

  /// 窓の環境（透過・言語）を面へ配る。
  func configure(translucency: ChromeTranslucency, localization: LocalizationStore) {
    editor.configure(translucency: translucency, localization: localization)
    spine.translucency = translucency
  }

  /// 配置を写す。`animated` なら面の clip と中身の位置を `Theme.Motion.faceSlide` で動かす
  /// （窓に付いていない・幅 0・Reduce Motion・幅が変わらないときは即時）。
  func set(_ faces: FaceLayout, animated: Bool) {
    guard faces != self.faces else { return }
    self.faces = faces
    settle(to: FaceGeometry.resolve(faces, width: bounds.width), animated: animated)
  }

  override func layout() {
    super.layout()
    clock?.cancel()
    clock = nil
    pendingDragSizes = nil
    apply(FaceGeometry.resolve(faces, width: bounds.width))
  }

  // MARK: - 配置

  private func settle(to target: FaceGeometry.Resolved, animated: Bool) {
    let animatable =
      animated && window != nil && bounds.width > 0
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if animatable, target.editorWidth != placedEditorWidth {
      startSlide(from: placedEditorWidth, to: target)
    } else {
      clock?.cancel()
      clock = nil
      apply(target)
    }
  }

  /// 解決結果を子へ写す（中身のサイズ・可視・焦点帯・背・位置）。
  private func apply(_ g: FaceGeometry.Resolved) {
    resolved = g
    applySizes(g)
    decorate(g)
    place(editorWidth: g.editorWidth, g)
    report(g.projection)
  }

  /// 中身のサイズ。端末は見えているときだけ寸法を覚える。
  private func applySizes(_ g: FaceGeometry.Resolved) {
    if g.terminalWidth > 0 { lastVisibleTerminalSize = terminalContentSize(g) }
    setSize(editor, editorContentSize(g))
    setSize(terminal, terminalContentSize(g))
  }

  /// 可視・焦点帯・背の見え方。
  private func decorate(_ g: FaceGeometry.Resolved) {
    editorFace.isHidden = g.editorWidth <= 0
    terminalFace.isHidden = g.terminalWidth <= 0
    editorFace.bandColor = g.isSplit && g.faces.focus == .editor ? Theme.Color.faceEditor : nil
    terminalFace.bandColor =
      g.isSplit && g.faces.focus == .terminal ? Theme.Color.faceTerminal : nil
    spine.look = g.projection.spineLook
  }

  /// 面・背・中身の位置を `editorWidth` で置く。中身のサイズは触らない（遷移中は補間した幅で呼ぶ）。
  /// 中身は錨側（エディター＝右・端末＝隣にエディターがあれば右、無ければ左）に付き、遷移中は面の
  /// 端から滑り込む。
  private func place(editorWidth eW: CGFloat, _ g: FaceGeometry.Resolved) {
    placedEditorWidth = eW
    let h = bounds.height
    let tW = g.contentWidth - eW
    editorFace.frame = NSRect(x: 0, y: 0, width: eW, height: h)
    spine.frame = NSRect(x: eW, y: 0, width: FaceGeometry.spine, height: h)
    terminalFace.frame = NSRect(x: eW + FaceGeometry.spine, y: 0, width: tW, height: h)
    let band = FaceGeometry.focusBand
    editor.frame.origin = NSPoint(x: eW - editor.frame.width, y: band)
    let terminalX = g.editorWidth > 0 ? tW - terminal.frame.width : 0
    terminal.frame.origin = NSPoint(x: terminalX, y: band)
  }

  private func editorContentSize(_ g: FaceGeometry.Resolved) -> CGSize {
    CGSize(width: g.editorWidth, height: max(0, bounds.height - FaceGeometry.focusBand))
  }

  private func terminalContentSize(_ g: FaceGeometry.Resolved) -> CGSize {
    let height = max(0, bounds.height - FaceGeometry.focusBand)
    if g.terminalWidth > 0 { return CGSize(width: g.terminalWidth, height: height) }
    return lastVisibleTerminalSize ?? CGSize(width: g.contentWidth, height: height)
  }

  private func setSize(_ view: NSView, _ size: CGSize) {
    if view.frame.size != size { view.setFrameSize(size) }
  }

  private func report(_ projection: FaceGeometry.Projection) {
    guard projection != reportedProjection else { return }
    reportedProjection = projection
    onProjectionChange?()
  }

  // MARK: - 背のドラッグ

  /// ポインタごとに面と背を置く。中身の resize は次のフレームへ間引く。
  private func drag(to x: CGFloat) {
    guard let origin = dragOrigin else { return }
    let g = FaceGeometry.resolve(FaceGeometry.drag(faces, from: origin, x: x), width: bounds.width)
    resolved = g
    pendingDragSizes = g
    decorate(g)
    place(editorWidth: g.editorWidth, g)
    report(g.projection)
    if clock == nil {
      clock = FrameClock(view: self) { [unowned self] in flushDragSizes() }
    }
  }

  private func flushDragSizes() {
    guard let g = pendingDragSizes else { return }
    pendingDragSizes = nil
    applySizes(g)
    place(editorWidth: g.editorWidth, g)
  }

  /// 離した: 端に寄せていれば閉じる配置をタブへ 1 回だけ求め、変わらなければその場で確定する。
  private func release() {
    guard dragOrigin != nil else { return }
    dragOrigin = nil
    clock?.cancel()
    clock = nil
    flushDragSizes()
    let final = FaceGeometry.release(resolved.faces, contentWidth: resolved.contentWidth)
    if final == faces {
      settle(to: FaceGeometry.resolve(faces, width: bounds.width), animated: true)
    } else {
      onFacesRequested?(final, true)
    }
  }

  // MARK: - 遷移

  private func startSlide(from: CGFloat, to target: FaceGeometry.Resolved) {
    clock?.cancel()
    resolved = target
    applySizes(target)
    // 現れる側は最初の 1 フレームから見せる。隠れる側は終端で隠す。
    if target.editorWidth > 0 { editorFace.isHidden = false }
    if target.terminalWidth > 0 { terminalFace.isHidden = false }
    editorFace.bandColor =
      target.isSplit && target.faces.focus == .editor ? Theme.Color.faceEditor : nil
    terminalFace.bandColor =
      target.isSplit && target.faces.focus == .terminal ? Theme.Color.faceTerminal : nil
    spine.look = target.projection.spineLook
    report(target.projection)
    let easing = UnitBezier(
      p1: Theme.Motion.faceSlideEasing.p1, p2: Theme.Motion.faceSlideEasing.p2)
    let start = CACurrentMediaTime()
    clock = FrameClock(view: self) { [unowned self] in
      let progress = min(1, CGFloat((CACurrentMediaTime() - start) / Theme.Motion.faceSlide))
      place(editorWidth: from + (target.editorWidth - from) * easing.value(at: progress), target)
      if progress >= 1 {
        clock?.cancel()
        clock = nil
        apply(FaceGeometry.resolve(faces, width: bounds.width))
      }
    }
  }

  /// display link 駆動でフレームごとに `tick` を呼ぶ。遷移の補間とドラッグ中の resize の間引きが共有する。
  private final class FrameClock {
    private var link: CADisplayLink?
    private let tick: () -> Void

    init(view: NSView, tick: @escaping () -> Void) {
      self.tick = tick
      link = view.displayLink(target: self, selector: #selector(step))
      link?.add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) { tick() }

    func cancel() {
      link?.invalidate()
      link = nil
    }
  }
}

/// 面の clip の器。上辺の焦点帯（分割中かつ焦点の面はその面のキー色、それ以外は透明）を描く。
private final class FaceClipView: NSView {
  var bandColor: NSColor? {
    didSet { if bandColor != oldValue { needsDisplay = true } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    clipsToBounds = true
    layerContentsRedrawPolicy = .duringViewResize
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard let bandColor else { return }
    bandColor.setFill()
    NSRect(x: 0, y: 0, width: bounds.width, height: FaceGeometry.focusBand).fill()
  }
}
