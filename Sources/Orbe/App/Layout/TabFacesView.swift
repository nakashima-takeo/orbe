import AppKit

/// タブの器: [エディター面 | 端末面] と、その境の取っ手（引き手と継ぎ目を 1 つの物にしたもの）。配置（`FaceLayout`）の
/// 正はタブが持ち、器は境の位置と形の動き（`FaceMotion`）を表示のフレームごとに進め、`FaceGeometry.frames` の矩形を子へ
/// 写すだけ。位置は引いている間はポインタに 1:1 で付き、⌘E・取っ手を押す・閉じる着地では位置のばねで確定した配置（鏡
/// `faces`）へ運ばれる。形は位置が決める目標を形のばねで追う。ホバーの進みも同じ時計で進める。
///
/// 相互作用は大きさに依らない形（割合）で持ち、`layout()` は今の状態を新しい大きさで置き直す——器の再レイアウトは chrome
/// 更新などから随時起きるので、確定配置で相互作用を捨てない。
///
/// 中身の寸法を変えるのは、動きの始め（現れる・広がる面）と終わり（両方のばねが止まったとき、縮む・隠れる面）の 1 回だけで、
/// 間は面の clip と中身の位置だけが動く。押しただけでは変えない。引いている間は表示のフレーム単位に間引いて配る。
/// 隠れた端末の中身は最後に見えていた寸法のまま据え置く（隠すたびの pty resize と scrollback の再折り返しを避ける）。
/// 隠れたまま生まれた端末は「戻したときに得る寸法」で起きる。
final class TabFacesView: NSView {
  let terminal: SurfaceScrollView
  let editor: EditorPaneView
  let handle = FaceHandleView()
  private let seamGround = SeamGroundView()
  private let editorFace: FaceClipView
  private let terminalFace: FaceClipView

  /// タブが `set` で写す配置の鏡。引いている間は書き換えない。位置のばねの行き先でもある。
  private(set) var faces: FaceLayout
  /// 今見えている配置を器の大きさで解いた結果（引いている間はポインタの値、動いている間は行き先）。
  private(set) var resolved: FaceGeometry.Resolved
  var projection: FaceGeometry.Projection { resolved.projection }
  /// 確定済みの配置（鏡 `faces`）を今の大きさで解いた結果。相互作用中でもポインタ値を映さないので、
  /// コマンド（⌘E）はこちらを読む。
  var committed: FaceGeometry.Resolved { FaceGeometry.resolve(faces, size: bounds.size) }
  /// 投影（ドット・分割中か）が変わった。器の幅で変わりうるので chrome はここから追従する。
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

  struct Sample {
    let time: CFTimeInterval
    let hx: CGFloat
  }

  /// 相互作用の状態。位置は割合で持ち、`layout()` が新しい幅へ写す。
  enum Interaction {
    case settled
    /// 押したが閾値の前: 掴んだ点・掴んだ瞬間の位置の割合・位置のばねが動いていたか。
    case pressed(x0: CGFloat, ratio0: CGFloat, wasFlying: Bool)
    /// 引いている間: 掴んだ点・掴んだ瞬間の位置の割合・離したときの速度を測る標本。
    case dragging(x0: CGFloat, ratio0: CGFloat, samples: [Sample])
    /// 確定した配置へ動いている途中（両方のばねが止まれば確定する）。
    case moving
  }
  var interaction: Interaction = .settled

  var motion = FaceMotion.rest(at: 0, width: 0)
  /// `motion` の位置が表す器の幅（幅が変わったら位置を伸縮する）。
  private var motionWidth: CGFloat = 0
  /// ホバーの進み（0→1）。的は「ポインタが取っ手の上にあるか、掴んでいるか」。
  private var hover: CGFloat = 0
  private var lastTick: CFTimeInterval?
  private var lastVisibleTerminalSize: CGSize?
  private var reportedProjection: FaceGeometry.Projection?
  /// 引いている間、次のフレームで中身へ配る寸法の元。
  var pendingDragSizes: FaceGeometry.Resolved?
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
    for view in [editorFace, terminalFace, seamGround, handle] {
      view.autoresizingMask = []
      addSubview(view)
    }
    wireHandle()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(accessibilityDisplayOptionsDidChange),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
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
    handle.onGrab = { [unowned self] x0 in grab(at: x0) }
    handle.onDrag = { [unowned self] x, time in drag(to: x, at: time) }
    handle.onRelease = { [unowned self] x, time in release(at: x, time: time) }
    handle.onClick = { [unowned self] in click() }
    handle.onPointerOver = { [unowned self] _ in updateClock() }
    handle.onScroll = { [unowned self] event in scrollFace(event) }
  }

  /// 取っ手の上のスクロールを、その点にある見えている面へ渡す。
  private func scrollFace(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let face = [editorFace, terminalFace].first { !$0.isHidden && $0.frame.contains(point) }
    face?.hitTest(point)?.scrollWheel(with: event)
  }

  /// 窓の環境（透過・言語・フォント割り当て・サイドバーの状態）を面と取っ手へ配る。
  func configure(
    translucency: ChromeTranslucency, localization: LocalizationStore,
    fontResolver: ChromeFontResolver, sidebar: EditorSidebarState
  ) {
    editor.configure(
      translucency: translucency, localization: localization, fontResolver: fontResolver,
      sidebar: sidebar)
    handle.translucency = translucency
    seamGround.translucency = translucency
  }

  /// 配置を写す。`animated` なら位置のばねで行き先へ運ぶ（窓に付いていない・幅 0・Reduce Motion なら即時）。
  /// 押さえている・引いている途中でも、外から来た配置が勝つ（掴みを打ち切る）。
  func set(_ faces: FaceLayout, animated: Bool) {
    guard faces != self.faces else { return }
    if isGrabbing {
      handle.cancelGrab()
      interaction = .settled
    }
    self.faces = faces
    let target = committed
    if animated, window != nil, bounds.width > 0, !reduceMotion {
      if motion.hx != target.shape.hx { motion.flying = true }
      beginMove(to: target)
    } else {
      settle(target)
    }
  }

  /// 器が再レイアウトされた（幅が変わったとは限らない）。今の状態を今の大きさで置き直す。
  override func layout() {
    super.layout()
    let resized = rescaleMotion()
    switch interaction {
    case .settled:
      settle(committed)
    case .dragging:
      pendingDragSizes = nil
      let g = dragResolved()
      showDrag(g)
      applySizes(g)
    case .pressed, .moving:
      if resized {
        resolved = committed
        distributeMoveSizes(to: resolved)
        report(resolved.projection)
      }
      placeMotion()
    }
  }

  // MARK: - 配置

  /// 動きを減らすか。システムの設定を写して変化に追従する（テストは直接決める）。真なら位置は行き先へ即時に移り、形は位置に
  /// 直結し、ホバーは即時に切り替わる。
  var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  @objc private func accessibilityDisplayOptionsDidChange() {
    reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  var isGrabbing: Bool {
    switch interaction {
    case .pressed, .dragging: true
    case .settled, .moving: false
    }
  }

  var maxPosition: CGFloat { FaceGeometry.maxPosition(bounds.width) }

  /// 幅が変わっていれば位置と速度を MAX の比で伸縮する（行き先は鏡から引くので伸縮しない）。変わったかを返す。
  private func rescaleMotion() -> Bool {
    let width = bounds.width
    guard width != motionWidth else { return false }
    let old = FaceGeometry.maxPosition(motionWidth)
    motionWidth = width
    if old > 0 {
      let scale = maxPosition / old
      motion.hx *= scale
      motion.v *= scale
    } else {
      motion = .rest(at: committed.shape.hx, width: width)
    }
    return true
  }

  /// 静止へ確定する: 動きを行き先に止め、解決結果を写す。
  func settle(_ target: FaceGeometry.Resolved) {
    motion = .rest(at: target.shape.hx, width: target.width)
    motionWidth = target.width
    interaction = .settled
    pendingDragSizes = nil
    apply(target)
    updateClock()
  }

  /// 確定した配置へ動き始める: 現れる・広がる面の中身を配り、行き先の焦点の印と投影を写す。
  func beginMove(to target: FaceGeometry.Resolved) {
    guard !reduceMotion else { return settle(target) }
    interaction = .moving
    resolved = target
    distributeMoveSizes(to: target)
    paint(target)
    report(target.projection)
    placeMotion()
    if motion.isAtRest(width: bounds.width) { settle(target) } else { updateClock() }
  }

  /// 動きの始めの中身の寸法: 行き先で見えている面の中身を、今の中身・今の面・行き先の面の幅の大きい方にする——
  /// どのコマでも見えている面が中身で覆われ、縮む・隠れる面の寸法は終わりの 1 回だけ変わる。
  private func distributeMoveSizes(to target: FaceGeometry.Resolved) {
    let now = FaceGeometry.frames(motion.shape, size: bounds.size)
    let h = bounds.height
    if target.editorWidth > 0 {
      let width = max(editor.frame.width, now.editor.width, target.editorWidth)
      setSize(editor, CGSize(width: width, height: h))
      editorFace.isHidden = false
    }
    if target.terminalWidth > 0 {
      let width = max(terminal.frame.width, now.terminal.width, target.terminalWidth)
      setSize(terminal, CGSize(width: width, height: h))
      terminalFace.isHidden = false
    }
  }

  /// 解決結果を子へ写す（中身のサイズ・可視・塗り・位置）。
  private func apply(_ g: FaceGeometry.Resolved) {
    resolved = g
    applySizes(g)
    setVisibility(g)
    paint(g)
    place(g.frames)
    report(g.projection)
  }

  /// 中身のサイズ。端末は見えているときだけ寸法を覚える。
  func applySizes(_ g: FaceGeometry.Resolved) {
    if g.terminalWidth > 0 { lastVisibleTerminalSize = terminalContentSize(g) }
    setSize(editor, g.frames.editor.size)
    setSize(terminal, terminalContentSize(g))
  }

  private func terminalContentSize(_ g: FaceGeometry.Resolved) -> CGSize {
    if g.terminalWidth > 0 { return g.frames.terminal.size }
    return lastVisibleTerminalSize ?? g.size
  }

  /// 幅 0 の面を隠す。
  func setVisibility(_ g: FaceGeometry.Resolved) {
    editorFace.isHidden = g.editorWidth <= 0
    terminalFace.isHidden = g.terminalWidth <= 0
  }

  /// 焦点の印。
  func paint(_ g: FaceGeometry.Resolved) {
    editorFace.markColor = g.isSplit && g.faces.focus == .editor ? Theme.Color.faceEditor : nil
    terminalFace.markColor =
      g.isSplit && g.faces.focus == .terminal ? Theme.Color.faceTerminal : nil
  }

  /// 動きの今の矩形を置く。確定した位置に止まっていれば、点に丸めた静止の矩形を置く。
  private func placeMotion() {
    let target = committed
    if motion.hx == target.shape.hx, motion.isAtRest(width: bounds.width) {
      place(target.frames)
    } else {
      place(FaceGeometry.frames(motion.shape, size: bounds.size))
    }
  }

  /// 面・両面の間の地・取っ手・中身の位置を矩形 `f` で置く。中身のサイズは触らない。中身は錨側（エディター＝右・端末＝
  /// 隣にエディターがあれば右、無ければ左）に付き、動きの間は面の端から滑り込む。
  func place(_ f: FaceGeometry.Frames) {
    editorFace.frame = f.editor
    terminalFace.frame = f.terminal
    seamGround.frame = f.gap
    seamGround.isHidden = f.gap.width <= 0
    handle.frame = f.handle
    handle.shape = (f.edgeOnLeft, f.t)
    handle.hover = hover
    editor.frame.origin = NSPoint(x: f.editor.width - editor.frame.width, y: 0)
    let terminalX = resolved.editorWidth > 0 ? f.terminal.width - terminal.frame.width : 0
    terminal.frame.origin = NSPoint(x: terminalX, y: 0)
  }

  func showDrag(_ g: FaceGeometry.Resolved) {
    resolved = g
    setVisibility(g)
    paint(g)
    place(g.frames)
    report(g.projection)
  }

  private func setSize(_ view: NSView, _ size: CGSize) {
    if view.frame.size != size { view.setFrameSize(size) }
  }

  func report(_ projection: FaceGeometry.Projection) {
    guard projection != reportedProjection else { return }
    reportedProjection = projection
    onProjectionChange?()
  }

  // MARK: - 時計

  private var hoverTarget: CGFloat { handle.isPointerOver || isGrabbing ? 1 : 0 }

  /// 時計が要るか: 引いている間・動きが止まっていない間・ホバーが的に届いていない間。
  var isAnimating: Bool {
    if case .dragging = interaction { return true }
    return !motion.isAtRest(width: bounds.width) || hover != hoverTarget
  }

  func updateClock() {
    if reduceMotion, hover != hoverTarget {
      hover = hoverTarget
      handle.hover = hover
    }
    if isAnimating {
      if clock == nil {
        lastTick = nil
        clock = FrameClock(view: self) { [unowned self] in frame() }
      }
    } else {
      clock?.cancel()
      clock = nil
    }
  }

  private func frame() {
    let now = CACurrentMediaTime()
    tick(dt: CGFloat(now - (lastTick ?? now)))
    lastTick = now
  }

  /// `dt` 秒の 1 フレーム: 動きとホバーを進め、今の状態で置く。動きが止まったら確定する。
  func tick(dt: CGFloat) {
    motion.step(dt: dt, width: bounds.width, goal: committed.shape.hx)
    let rate = dt / CGFloat(Theme.Motion.quick)
    hover =
      hoverTarget > hover ? min(hoverTarget, hover + rate) : max(hoverTarget, hover - rate)
    switch interaction {
    case .dragging:
      let g = dragResolved()
      pendingDragSizes = g
      showDrag(g)
      flushDragSizes()
    case .moving where motion.isAtRest(width: bounds.width):
      settle(committed)
    case .settled, .pressed, .moving:
      placeMotion()
    }
    updateClock()
  }
}
