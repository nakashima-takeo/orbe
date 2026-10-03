import AppKit
import SwiftUI

/// タブの器: [エディター面 | 背 | 端末面]。配置（`FaceLayout`）を幅で解いた結果を子の frame に写すだけで、
/// 配置の正はタブが持つ。面は clip の器で、中身の幅は面の幅に等しい。
///
/// 相互作用（背のドラッグ・面の遷移）は幅に依らない形（割合と時刻）で持ち、`layout()` はそれを新しい幅へ
/// 写す——器の再レイアウトは chrome 更新などから随時起きるので、確定配置で相互作用を捨てない。
///
/// 隠れた端末の中身は最後に見えていた寸法のまま据え置く（隠すたびの pty resize と scrollback の
/// 再折り返しを避ける）。隠れたまま生まれた端末は「戻したときに得る寸法」で起きる。
/// 遷移は「中身のサイズは遷移開始時に 1 回・面の clip と中身の位置だけ動く」。背のドラッグ中は
/// 面と背をポインタごとに置き、中身の resize は表示のフレーム単位に間引く。
final class TabFacesView: NSView {
  let terminal: SurfaceScrollView
  let editor: EditorPaneView
  let spine = SpineView()
  private let editorFace: FaceClipView
  private let terminalFace: FaceClipView

  /// タブが `set` で写す配置の鏡。ドラッグ中は書き換えない。遷移の終点でもある。
  private(set) var faces: FaceLayout
  /// 今見えている配置を器の幅で解いた結果（ドラッグ中はポインタの値、遷移中は終点）。
  private(set) var resolved: FaceGeometry.Resolved
  var projection: FaceGeometry.Projection { resolved.projection }
  /// 確定済みの配置（鏡 `faces`）を今の幅で解いた結果。相互作用中でもポインタ値を映さないので、
  /// コマンド（⌘E）はこちらを読む。
  var committed: FaceGeometry.Resolved { FaceGeometry.resolve(faces, width: bounds.width) }
  /// 投影（ドット・背の見え方・分割中か）が変わった。器の幅で変わりうるので chrome はここから追従する。
  var onProjectionChange: (() -> Void)?
  /// 背のクリック／離したときに求める配置。タブが正規化して状態に置き、`set` で戻す。
  var onFacesRequested: ((FaceLayout, _ animated: Bool) -> Void)?
  /// 窓の first responder が面の配下に入った（面の焦点の記憶はここからだけ導く）。
  var onFaceFocused: ((Face) -> Void)?
  private var responderObservation: NSKeyValueObservation?

  /// 焦点の面の responder（エディターは文書があればそのテキスト面、無ければ pane）。
  var focusTarget: NSView { faces.focus == .editor ? editor.focusTarget : terminal.surfaceView }

  /// `responder` がどちらの面の配下か（面の外なら nil）。
  func face(containing responder: NSResponder?) -> Face? {
    guard let view = responder as? NSView else { return nil }
    if view.isDescendant(of: editor) { return .editor }
    if view.isDescendant(of: terminal) { return .terminal }
    return nil
  }

  /// 相互作用の状態。幅に依らない形で持ち、`layout()` が新しい幅へ写す。
  private enum Interaction {
    case settled
    /// 背のドラッグ中: 掴んだ瞬間の配置と、ポインタが求める現在の配置。
    case dragging(origin: FaceLayout, current: FaceLayout)
    /// 遷移中: 起点のエディター割合と開始時刻。終点は鏡 `faces`。
    case sliding(fromRatio: Double, start: CFTimeInterval)
  }
  private var interaction: Interaction = .settled

  private var lastVisibleTerminalSize: CGSize?
  private var reportedProjection: FaceGeometry.Projection?
  /// 今置いてあるエディター幅（遷移の起点）。
  private var placedEditorWidth: CGFloat = 0
  /// ドラッグ中、次のフレームで中身へ配る寸法の元。
  private var pendingDragSizes: FaceGeometry.Resolved?
  private var clock: FrameClock?

  override var isFlipped: Bool { true }

  init(terminal: SurfaceScrollView, editor: EditorPaneView, faces: FaceLayout) {
    self.terminal = terminal
    self.editor = editor
    self.faces = faces
    resolved = FaceGeometry.resolve(faces, width: 0)
    editorFace = FaceClipView(content: editor)
    terminalFace = FaceClipView(content: terminal)
    super.init(frame: .zero)
    for view in [editorFace, spine, terminalFace] {
      view.autoresizingMask = []
      addSubview(view)
    }
    wireSpine()
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  deinit { clock?.cancel() }

  /// 窓の first responder を見張り、面の配下に入ったら告げる——焦点がどの経路で入っても（テキスト面・端末・pane・
  /// サイドバーの SwiftUI の入力欄）同じ 1 か所で面の記憶が追従する。面の外（パレット・窓）へ出ても記憶は残す。
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    responderObservation = window?.observe(\.firstResponder) { [weak self] window, _ in
      MainActor.assumeIsolated {
        guard let self, let face = self.face(containing: window.firstResponder) else { return }
        self.onFaceFocused?(face)
      }
    }
  }

  /// 背の操作を器の状態へ結ぶ。init の外に置き、閉包が読む `faces` を常に鏡（プロパティ）にする。
  private func wireSpine() {
    spine.onGrab = { [unowned self] in
      stopClock()
      interaction = .dragging(origin: faces, current: faces)
      window?.makeFirstResponder(focusTarget)
    }
    spine.onDrag = { [unowned self] x in drag(to: x) }
    spine.onRelease = { [unowned self] in release() }
    spine.onClick = { [unowned self] in
      interaction = .settled
      onFacesRequested?(FaceGeometry.spineClick(resolved), true)
    }
  }

  /// 窓の環境（透過・言語・フォント割り当て・サイドバーの状態）を面へ配る。
  func configure(
    translucency: ChromeTranslucency, localization: LocalizationStore,
    fontResolver: ChromeFontResolver, sidebar: EditorSidebarState
  ) {
    editor.configure(
      translucency: translucency, localization: localization, fontResolver: fontResolver,
      sidebar: sidebar)
    spine.translucency = translucency
  }

  /// 配置を写す。`animated` なら面の clip と中身の位置を `Theme.Motion.faceSlide` で動かす
  /// （窓に付いていない・幅 0・Reduce Motion・幅が変わらないときは即時）。
  func set(_ faces: FaceLayout, animated: Bool) {
    guard faces != self.faces else { return }
    self.faces = faces
    settle(to: committed, animated: animated)
  }

  /// 器が再レイアウトされた（幅が変わったとは限らない）。今の相互作用を今の幅で置き直す。
  override func layout() {
    super.layout()
    switch interaction {
    case .settled:
      apply(committed)
    case .dragging(_, let current):
      pendingDragSizes = nil
      apply(FaceGeometry.resolve(current, width: bounds.width))
    case .sliding:
      prepareSlide(to: committed)
      slideFrame(now: CACurrentMediaTime())
    }
  }

  // MARK: - 配置

  private func settle(to target: FaceGeometry.Resolved, animated: Bool) {
    let animatable =
      animated && window != nil && bounds.width > 0
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if animatable, target.editorWidth != placedEditorWidth {
      startSlide(from: placedEditorWidth, to: target)
    } else {
      stopClock()
      interaction = .settled
      apply(target)
    }
  }

  /// 解決結果を子へ写す（中身のサイズ・可視・塗り・位置）。
  private func apply(_ g: FaceGeometry.Resolved) {
    resolved = g
    applySizes(g)
    setVisibility(g)
    paint(g)
    place(editorWidth: g.editorWidth, g)
    report(g.projection)
  }

  /// 中身のサイズ。端末は見えているときだけ寸法を覚える。
  private func applySizes(_ g: FaceGeometry.Resolved) {
    if g.terminalWidth > 0 { lastVisibleTerminalSize = terminalContentSize(g) }
    setSize(editor, editorContentSize(g))
    setSize(terminal, terminalContentSize(g))
  }

  /// 幅 0 の面を隠す。
  private func setVisibility(_ g: FaceGeometry.Resolved) {
    editorFace.isHidden = g.editorWidth <= 0
    terminalFace.isHidden = g.terminalWidth <= 0
  }

  /// 焦点の印と背の見え方。
  private func paint(_ g: FaceGeometry.Resolved) {
    editorFace.markColor = g.isSplit && g.faces.focus == .editor ? Theme.Color.faceEditor : nil
    terminalFace.markColor =
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
    editor.frame.origin = NSPoint(x: eW - editor.frame.width, y: 0)
    let terminalX = g.editorWidth > 0 ? tW - terminal.frame.width : 0
    terminal.frame.origin = NSPoint(x: terminalX, y: 0)
  }

  private func editorContentSize(_ g: FaceGeometry.Resolved) -> CGSize {
    CGSize(width: g.editorWidth, height: bounds.height)
  }

  private func terminalContentSize(_ g: FaceGeometry.Resolved) -> CGSize {
    if g.terminalWidth > 0 { return CGSize(width: g.terminalWidth, height: bounds.height) }
    return lastVisibleTerminalSize ?? CGSize(width: g.contentWidth, height: bounds.height)
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
    guard case .dragging(let origin, _) = interaction else { return }
    let g0 = FaceGeometry.resolve(origin, width: bounds.width)
    let current = FaceGeometry.drag(from: g0, x: x)
    interaction = .dragging(origin: origin, current: current)
    let g = FaceGeometry.resolve(current, width: bounds.width)
    resolved = g
    pendingDragSizes = g
    setVisibility(g)
    paint(g)
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
    guard case .dragging(_, let current) = interaction else { return }
    interaction = .settled
    stopClock()
    flushDragSizes()
    let final = FaceGeometry.release(current, contentWidth: resolved.contentWidth)
    if final == faces {
      settle(to: committed, animated: true)
    } else {
      onFacesRequested?(final, true)
    }
  }

  // MARK: - 遷移

  private func startSlide(from: CGFloat, to target: FaceGeometry.Resolved) {
    stopClock()
    let start = CACurrentMediaTime()
    interaction = .sliding(fromRatio: Double(from / target.contentWidth), start: start)
    prepareSlide(to: target)
    clock = FrameClock(view: self) { [unowned self] in slideFrame(now: CACurrentMediaTime()) }
    slideFrame(now: start)
  }

  /// 遷移の終点を据える: 中身のサイズは 1 回で確定し、現れる側は最初の 1 フレームから見せ、隠れる側は
  /// 終端まで倒さない。塗りは終点の規則。
  private func prepareSlide(to target: FaceGeometry.Resolved) {
    resolved = target
    applySizes(target)
    if target.editorWidth > 0 { editorFace.isHidden = false }
    if target.terminalWidth > 0 { terminalFace.isHidden = false }
    paint(target)
    report(target.projection)
  }

  /// 遷移の 1 フレーム。`now` の進行で起点と終点の間に背を置き、終端で確定配置へ着地する。
  func slideFrame(now: CFTimeInterval) {
    guard case .sliding(let fromRatio, let start) = interaction else { return }
    let target = committed
    let progress = min(1, (now - start) / Theme.Motion.faceSlide)
    let eased = CGFloat(Theme.Motion.faceSlideCurve.value(at: max(0, progress)))
    let from = CGFloat(fromRatio) * target.contentWidth
    place(editorWidth: from + (target.editorWidth - from) * eased, target)
    if progress >= 1 {
      stopClock()
      interaction = .settled
      apply(target)
    }
  }

  private func stopClock() {
    clock?.cancel()
    clock = nil
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

/// 面の clip の器。中身を面いっぱいに置き、分割中の焦点の印（面のキー色の細い帯）を中身の上辺へ重ねる——
/// 印は場所を取らないので、焦点が移っても中身は動かない。
private final class FaceClipView: NSView {
  private let mark = FocusMarkView()
  /// 印の色。nil なら印を出さない。
  var markColor: NSColor? {
    get { mark.color }
    set { mark.color = newValue }
  }

  init(content: NSView) {
    super.init(frame: .zero)
    wantsLayer = true
    clipsToBounds = true
    content.autoresizingMask = []
    addSubview(content)
    addSubview(mark)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    mark.frame = NSRect(x: 0, y: 0, width: newSize.width, height: FaceGeometry.focusBand)
  }
}

/// 焦点の印。中身より手前に重なるが、クリックやドラッグは中身へ通す。
private final class FocusMarkView: NSView {
  var color: NSColor? {
    didSet {
      guard color != oldValue else { return }
      isHidden = color == nil
      needsDisplay = true
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    isHidden = true
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    color?.setFill()
    bounds.fill()
  }
}
