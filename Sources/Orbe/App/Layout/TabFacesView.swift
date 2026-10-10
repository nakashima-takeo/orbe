import AppKit
import SwiftUI

/// タブの器: [エディター面 | 端末面] と取っ手（引き手・継ぎ目）。配置（`FaceLayout`）を器の大きさで解いた
/// 結果を子の frame に写すだけで、配置の正はタブが持つ。面は clip の器。全面は器いっぱい、分割中は両面が角丸の
/// カードになって余白と間を空けて並び、カードの外側に器の地が見える。引き手は面の上に重なり、継ぎ目は間そのもの。
///
/// 相互作用（取っ手を引く・面の遷移）は大きさに依らない形（割合と時刻）で持ち、`layout()` はそれを新しい大きさへ
/// 写す——器の再レイアウトは chrome 更新などから随時起きるので、確定配置で相互作用を捨てない。カードで描くかは
/// 今の動きで決まる: 静止中と引いている間は配置が分割か、遷移中は起点か終点が分割か。
///
/// 隠れた端末の中身は最後に見えていた寸法のまま据え置く（隠すたびの pty resize と scrollback の
/// 再折り返しを避ける）。隠れたまま生まれた端末は「戻したときに得る寸法」で起きる。
/// 遷移は「どのコマでも見えている面は中身で覆われ、中身の寸法は始めか終わりの 1 回だけ変わり、間は面の clip と中身の
/// 位置だけ動く」。取っ手を引いている間は
/// 面と取っ手をポインタごとに置き、中身の resize は表示のフレーム単位に間引く。
final class TabFacesView: NSView {
  let terminal: SurfaceScrollView
  let editor: EditorPaneView
  let handle = FaceHandleView()
  private let ground = FaceGroundView()
  private let editorFace: FaceClipView
  private let terminalFace: FaceClipView

  /// タブが `set` で写す配置の鏡。ドラッグ中は書き換えない。遷移の終点でもある。
  private(set) var faces: FaceLayout
  /// 今見えている配置を器の大きさで解いた結果（ドラッグ中はポインタの値、遷移中は終点）。
  private(set) var resolved: FaceGeometry.Resolved
  var projection: FaceGeometry.Projection { resolved.projection }
  /// 確定済みの配置（鏡 `faces`）を今の大きさで解いた結果。相互作用中でもポインタ値を映さないので、
  /// コマンド（⌘E）はこちらを読む。
  var committed: FaceGeometry.Resolved { FaceGeometry.resolve(faces, size: bounds.size) }
  /// 投影（ドット・取っ手の見え方・分割中か）が変わった。器の幅で変わりうるので chrome はここから追従する。
  var onProjectionChange: (() -> Void)?
  /// 取っ手を押した／離したときに求める配置。タブが正規化して状態に置き、`set` で戻す。
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
    /// 取っ手を引いている間: 掴んだ瞬間の配置と、ポインタが求める現在の配置と、掴んだ点から境までのずれ。
    case dragging(origin: FaceLayout, current: FaceLayout, offset: CGFloat)
    /// 遷移中: 起点の置き方と開始時刻と、カードで描くか（起点か終点が分割なら）。終点は鏡 `faces`。
    case sliding(from: FaceGeometry.Placement, start: CFTimeInterval, cards: Bool)
  }
  private var interaction: Interaction = .settled

  private var lastVisibleTerminalSize: CGSize?
  private var reportedProjection: FaceGeometry.Projection?
  /// 今置いてある置き方（遷移の起点と、掴んだ瞬間の境）。`place` だけが書く。
  private var placed = FaceGeometry.Placement(ratio: 0, cards: false)
  /// ドラッグ中、次のフレームで中身へ配る寸法の元。
  private var pendingDragSizes: FaceGeometry.Resolved?
  private var clock: FrameClock?

  override var isFlipped: Bool { true }

  init(terminal: SurfaceScrollView, editor: EditorPaneView, faces: FaceLayout) {
    self.terminal = terminal
    self.editor = editor
    self.faces = faces
    resolved = FaceGeometry.resolve(faces, size: .zero)
    editorFace = FaceClipView(content: editor)
    terminalFace = FaceClipView(content: terminal)
    super.init(frame: .zero)
    for view in [ground, editorFace, terminalFace, handle] {
      view.autoresizingMask = []
      addSubview(view)
    }
    wireHandle()
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

  /// 取っ手の操作を器の状態へ結ぶ。init の外に置き、閉包が読む `faces` を常に鏡（プロパティ）にする。
  private func wireHandle() {
    handle.onGrab = { [unowned self] x0 in
      stopClock()
      // 掴んだ瞬間に見えていた境（間の中央。全面では縁）からのずれ。間の半幅に収めるので、引き手から引いても間が
      // ポインタの下に来る。
      let seam = FaceGeometry.frames(placed, size: bounds.size).gap.midX
      let reach = Theme.Layout.faceSplitGap / 2
      let offset = min(max(x0 - seam, -reach), reach)
      interaction = .dragging(origin: faces, current: faces, offset: offset)
      window?.makeFirstResponder(focusTarget)
    }
    handle.onDrag = { [unowned self] x in drag(to: x) }
    handle.onRelease = { [unowned self] in release() }
    handle.onClick = { [unowned self] in
      interaction = .settled
      onFacesRequested?(FaceGeometry.handleClick(resolved), true)
    }
    handle.onScroll = { [unowned self] event in scrollFace(event) }
  }

  /// 取っ手の上のスクロールを、その点にある見えている面へ渡す。
  private func scrollFace(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let face = [editorFace, terminalFace].first { !$0.isHidden && $0.frame.contains(point) }
    face?.hitTest(point)?.scrollWheel(with: event)
  }

  /// 窓の環境（透過・言語・フォント割り当て・サイドバーの状態）を面へ配る。
  func configure(
    translucency: ChromeTranslucency, localization: LocalizationStore,
    fontResolver: ChromeFontResolver, sidebar: EditorSidebarState
  ) {
    editor.configure(
      translucency: translucency, localization: localization, fontResolver: fontResolver,
      sidebar: sidebar)
    ground.translucency = translucency
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
    case .dragging(_, let current, _):
      pendingDragSizes = nil
      apply(FaceGeometry.resolve(current, size: bounds.size))
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
    if animatable, target.placement != placed {
      startSlide(to: target)
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
    place(g.placement, g)
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

  /// 焦点の印と取っ手の見え方。
  private func paint(_ g: FaceGeometry.Resolved) {
    editorFace.markColor = g.isSplit && g.faces.focus == .editor ? Theme.Color.faceEditor : nil
    terminalFace.markColor =
      g.isSplit && g.faces.focus == .terminal ? Theme.Color.faceTerminal : nil
    handle.look = g.projection.handleLook
  }

  /// 面・器の地・取っ手・中身の位置を置き方 `p` で置く。中身のサイズは触らない（遷移中は補間した置き方で呼ぶ）。
  /// 中身は上端と錨側（エディター＝右・端末＝隣にエディターがあれば右、無ければ左）に付き、遷移中は面の
  /// 端から滑り込む。取っ手の形は `g` の見え方で決まり、引き手は隠れた側の縁に重なり、継ぎ目は間そのもの。
  private func place(_ p: FaceGeometry.Placement, _ g: FaceGeometry.Resolved) {
    placed = p
    let f = FaceGeometry.frames(p, size: g.size)
    editorFace.frame = f.editor
    terminalFace.frame = f.terminal
    let radius = p.cards ? Theme.Radius.faceCard : 0
    editorFace.cornerRadius = radius
    terminalFace.cornerRadius = radius
    ground.frame = bounds
    ground.cards = p.cards ? f : nil
    handle.frame = handleFrame(g.projection.handleLook, gap: f.gap, size: g.size)
    editor.frame.origin = NSPoint(x: f.editor.width - editor.frame.width, y: 0)
    let terminalX = g.editorWidth > 0 ? f.terminal.width - terminal.frame.width : 0
    terminal.frame.origin = NSPoint(x: terminalX, y: 0)
  }

  private func handleFrame(
    _ look: FaceGeometry.HandleLook, gap: CGRect, size: CGSize
  ) -> NSRect {
    let notch = Theme.Layout.faceNotch
    let notchY = size.height / 2 - notch.height / 2
    switch look {
    case .notch(.editor):
      return NSRect(x: 0, y: notchY, width: notch.width, height: notch.height)
    case .notch(.terminal):
      return NSRect(
        x: size.width - notch.width, y: notchY, width: notch.width, height: notch.height)
    case .seam:
      return gap
    }
  }

  private func editorContentSize(_ g: FaceGeometry.Resolved) -> CGSize {
    g.frames.editor.size
  }

  private func terminalContentSize(_ g: FaceGeometry.Resolved) -> CGSize {
    if g.terminalWidth > 0 { return g.frames.terminal.size }
    return lastVisibleTerminalSize ?? g.size
  }

  private func setSize(_ view: NSView, _ size: CGSize) {
    if view.frame.size != size { view.setFrameSize(size) }
  }

  private func report(_ projection: FaceGeometry.Projection) {
    guard projection != reportedProjection else { return }
    reportedProjection = projection
    onProjectionChange?()
  }

  // MARK: - 取っ手を引く

  /// ポインタごとに面と取っ手を置く。中身の resize は次のフレームへ間引く。
  private func drag(to x: CGFloat) {
    guard case .dragging(let origin, _, let offset) = interaction else { return }
    let g0 = FaceGeometry.resolve(origin, size: bounds.size)
    let current = FaceGeometry.drag(from: g0, x: x - offset)
    interaction = .dragging(origin: origin, current: current, offset: offset)
    let g = FaceGeometry.resolve(current, size: bounds.size)
    resolved = g
    pendingDragSizes = g
    setVisibility(g)
    paint(g)
    place(g.placement, g)
    report(g.projection)
    if clock == nil {
      clock = FrameClock(view: self) { [unowned self] in flushDragSizes() }
    }
  }

  private func flushDragSizes() {
    guard let g = pendingDragSizes else { return }
    pendingDragSizes = nil
    applySizes(g)
    place(g.placement, g)
  }

  /// 離した: 端に寄せていれば閉じる配置をタブへ 1 回だけ求め、変わらなければその場で確定する。
  private func release() {
    guard case .dragging(_, let current, _) = interaction else { return }
    interaction = .settled
    stopClock()
    flushDragSizes()
    let final = FaceGeometry.release(current, width: resolved.width)
    if final == faces {
      settle(to: committed, animated: true)
    } else {
      onFacesRequested?(final, true)
    }
  }

  // MARK: - 遷移

  private func startSlide(to target: FaceGeometry.Resolved) {
    stopClock()
    let start = CACurrentMediaTime()
    interaction = .sliding(from: placed, start: start, cards: placed.cards || target.isSplit)
    prepareSlide(to: target)
    clock = FrameClock(view: self) { [unowned self] in slideFrame(now: CACurrentMediaTime()) }
    slideFrame(now: start)
  }

  /// 遷移の終点を据える: どのコマでも見えている面が中身で覆われるようにする——隠れていく面の中身は最後に見えていた寸法の
  /// まま（遷移中に器が resize されても据え置く）、起点でも見えていた残る面の中身は起点と終点の面の大きさの大きい方
  /// （幅も高さも）、現れる面の中身は終点の大きさ。中身の寸法が変わるのは、現れる・広がる面はここ、縮む・隠れる面は終端の
  /// `apply` の 1 回だけ。現れる側は最初の 1 フレームから見せ、隠れる側は終端まで倒さない。塗りは終点の規則。
  private func prepareSlide(to target: FaceGeometry.Resolved) {
    guard case .sliding(let from, _, _) = interaction else { return }
    resolved = target
    let start = FaceGeometry.frames(from, size: target.size)
    func size(from start: CGRect, to end: CGRect) -> CGSize {
      guard start.width > 0 else { return end.size }
      return CGSize(
        width: max(start.width, end.width), height: max(start.height, end.height))
    }
    if target.editorWidth > 0 {
      setSize(editor, size(from: start.editor, to: target.frames.editor))
      editorFace.isHidden = false
    }
    if target.terminalWidth > 0 {
      setSize(terminal, size(from: start.terminal, to: target.frames.terminal))
      terminalFace.isHidden = false
    }
    paint(target)
    report(target.projection)
  }

  /// 遷移の 1 フレーム。`now` の進行で起点と終点の割合の間に置き、終端で確定配置へ着地する（分割から出るときは
  /// ここで器いっぱいへ戻る）。
  func slideFrame(now: CFTimeInterval) {
    guard case .sliding(let from, let start, let cards) = interaction else { return }
    let target = committed
    let progress = min(1, (now - start) / Theme.Motion.faceSlide)
    let eased = Theme.Motion.faceSlideCurve.value(at: max(0, progress))
    let ratio = from.ratio + (target.placement.ratio - from.ratio) * eased
    place(FaceGeometry.Placement(ratio: ratio, cards: cards), target)
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
