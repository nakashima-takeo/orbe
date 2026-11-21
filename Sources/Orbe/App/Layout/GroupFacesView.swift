import AppKit
import QuartzCore

/// 連の器: 端末面の上にエディター面を重ねた 2 層。端末面・その中の端末・エディター面は常に器いっぱいで、器は渡された見せ方
/// （端末・エディター・透かし）を、両面の見せる・隠すとエディター面の濃さ（不透明度）とクリックの届き先へ写すだけ。見せ方の正は
/// 窓（`WindowController`）が持ち、content の照合が渡す。
///
/// 端末面には連の materialize 済みのタブの端末を何枚でも差せ、見せるのはそのうち 1 枚。端末はどれも器の寸法に従う（エディターに
/// 覆われている間も、見せていない兄弟も）ので、開閉でも、連の中で見せる端末を替えても resize は起きない。
///
/// 端末を描くかは器が端末へ渡す（`syncRendering`）。描くのは見せている 1 枚で、器が（祖先を含めて）隠れていないときだけ。
/// エディターに覆われて端末面が隠れている間も描き続ける——見せた最初のフレームに最新の描画結果を出すため。
///
/// 切り替わりの動きはエディター面の濃さのフェード 1 つで、見せ方とクリックの届き先は動きを待たずに切り替わる。両面の可視と
/// 濃さは「見せ方」と「動きの途中か」の 2 つから `applyFaces` が 1 か所で導く。
final class GroupFacesView: NSView {
  let editor: EditorPaneView
  /// 端末面に差している端末（連の materialize 済みのタブの端末）。
  private(set) var terminals: [SurfaceScrollView] = []
  /// 見せている 1 枚。
  private(set) var shownTerminal: SurfaceScrollView?
  private let terminalFace = NSView()
  /// エディター面。pane を包む view で、開閉の可視と濃さはここに掛ける——pane 自身の可視には触れないので、pane を器から
  /// 取り出して単独で載せる場（gallery・flow の fixture）でもそのまま見える。
  private let editorFace = NSView()

  /// 見せ方。
  enum Mode {
    case terminal
    case editor
    /// 透かし: エディターを開いたまま、エディター面を見えなくして端末を見せる。エディター面は隠さないので first responder は
    /// 動かない。
    case peek
  }

  /// 見せ方。器は端末で生まれる。
  private(set) var mode = Mode.terminal
  /// エディターを開いているか（見せ方が端末でない）。
  var isEditorOpen: Bool { mode != .terminal }
  /// 切り替わりの動きの途中か。
  private(set) var isFading = false
  /// 最後に始めた動きの番号。置き換えられた動きの完了通知は、置き換えた直後に届くので、番号で見分けて捨てる。
  private var fadeGeneration = 0

  /// 動きを減らすか。システムの設定を写して変化に追従する（テストは直接決める）。真なら切り替わりは即時。
  var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  override var isFlipped: Bool { true }

  init(editor: EditorPaneView) {
    self.editor = editor
    super.init(frame: .zero)
    wantsLayer = true
    editorFace.wantsLayer = true
    editor.autoresizingMask = []
    editorFace.addSubview(editor)
    for view in [terminalFace, editorFace] {
      view.autoresizingMask = []
      addSubview(view)
    }
    applyFaces()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(accessibilityDisplayOptionsDidChange),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  @objc private func accessibilityDisplayOptionsDidChange() {
    reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// 窓の環境（透過・言語・フォント割り当て・サイドバーの状態・diff の見せ方）をエディター面へ配る。
  func configure(
    translucency: ChromeTranslucency, localization: LocalizationStore,
    fontResolver: ChromeFontResolver, sidebar: EditorSidebarState, diffModes: EditorDiffModeState
  ) {
    editor.configure(
      translucency: translucency, localization: localization, fontResolver: fontResolver,
      sidebar: sidebar, diffModes: diffModes)
  }

  // MARK: - 端末

  /// 端末を端末面へ差す（隠したまま）。寸法は器の大きさで、窓に付く前に確定させる——器が窓にあれば差した瞬間に surface が
  /// 生まれ、その寸法で pty が起動する。
  func add(terminal: SurfaceScrollView) {
    guard !terminals.contains(where: { $0 === terminal }) else { return }
    terminals.append(terminal)
    terminal.isHidden = true
    terminal.autoresizingMask = []
    terminal.frame = bounds
    terminal.layoutSubtreeIfNeeded()
    terminalFace.addSubview(terminal)
    syncRendering()
  }

  /// 端末を端末面から外し、描かないと渡す（既に別の器へ移っていれば、どちらもしない）。
  func remove(terminal: SurfaceScrollView) {
    terminals.removeAll { $0 === terminal }
    if shownTerminal === terminal { shownTerminal = nil }
    guard terminal.superview === terminalFace else { return }
    terminal.removeFromSuperview()
    terminal.surfaceView.wantsRendering = false
  }

  /// 見せる端末を替える。見せ方とエディターには触れない。
  func show(terminal: SurfaceScrollView) {
    guard terminal !== shownTerminal, terminals.contains(where: { $0 === terminal }) else {
      return
    }
    shownTerminal?.isHidden = true
    shownTerminal = terminal
    terminal.isHidden = false
    syncRendering()
  }

  /// 配下の端末へ描くかを渡す。端末面の可視（エディターに覆われているか）は関わらない。
  private func syncRendering() {
    let visible = !isHiddenOrHasHiddenAncestor
    for terminal in terminals {
      terminal.surfaceView.wantsRendering = visible && terminal === shownTerminal
    }
  }

  /// 器か祖先が隠れた・現れた。窓に付いていない器にも届く。
  override func viewDidHide() {
    super.viewDidHide()
    syncRendering()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    syncRendering()
  }

  override func layout() {
    super.layout()
    for view in [terminalFace, editorFace] + terminals where view.frame != bounds {
      view.frame = bounds
    }
    if editor.superview === editorFace, editor.frame != bounds { editor.frame = bounds }
  }

  // MARK: - 見せ方

  /// 見せ方を写す。同じ値なら何もしない（進行中の動きを切らない）。エディター面の濃さが変わる切り替えだけがフェードし、長さは
  /// エディターと透かしの間なら `quick`、端末とエディターの間なら `base`。`animated` でも、器が窓に無い・器か祖先が隠れている・
  /// 動きを減らす設定なら即時。動きの途中で反転したら、今見えている濃さから逆へ続ける。
  func show(_ next: Mode, animated: Bool) {
    guard next != mode else { return }
    let previous = mode
    mode = next
    if next == .peek { showArrowPointer() }
    guard (previous == .editor) != (next == .editor) else {
      applyFaces()
      return
    }
    fadeGeneration += 1
    let layer = editorFace.layer
    guard animated, window != nil, !isHiddenOrHasHiddenAncestor, !reduceMotion, let layer else {
      layer?.removeAnimation(forKey: Self.fadeKey)
      isFading = false
      applyFaces()
      return
    }
    let from = layer.presentation()?.opacity ?? layer.opacity
    isFading = true
    applyFaces()
    let generation = fadeGeneration
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = from
    fade.toValue = Float(editorFace.alphaValue)
    fade.duration = previous == .peek || next == .peek ? Theme.Motion.quick : Theme.Motion.base
    let ease = Theme.Motion.easing
    fade.timingFunction = CAMediaTimingFunction(
      controlPoints: Float(ease.p1.x), Float(ease.p1.y), Float(ease.p2.x), Float(ease.p2.y))
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      guard let self, generation == fadeGeneration else { return }
      isFading = false
      applyFaces()
    }
    layer.add(fade, forKey: Self.fadeKey)
    CATransaction.commit()
  }

  private static let fadeKey = "editorFade"

  /// 見せ方と動きの途中かから、両面の可視とエディター面の濃さを写す。エディター面を隠すのは見せ方が端末で動きの途中でない
  /// ときだけ（透かしでは隠さず濃さ 0）。端末面を隠すのは見せ方がエディターで動きの途中でないときだけ（描画は続く）。
  private func applyFaces() {
    editorFace.alphaValue = mode == .editor ? 1 : 0
    editorFace.isHidden = mode == .terminal && !isFading
    terminalFace.isHidden = mode == .editor && !isFading
  }

  /// 透かしへ入るとき、ポインタが器の上なら矢印にする。透かしている間、見えないエディターはポインタを持たない（窓の hit-test が
  /// 器に解ける）ので、入る前の形が残らないようにする。
  private func showArrowPointer() {
    guard let window, window.isKeyWindow else { return }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    if bounds.contains(point) { NSCursor.arrow.set() }
  }

  /// クリックの届き先は見せ方に従う。閉じる途中のエディター面はまだ見えているが、クリックは下の端末面へ通す（エディター面が
  /// クリックを受けると、隠れる view に first responder が残る）。透かしている間は器自身が受ける——見えないエディターのボタンを
  /// 押さず、端末へフォーカスを移さない。
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, frame.contains(point) else { return super.hitTest(point) }
    switch mode {
    case .peek: return self
    case .terminal where isFading: return terminalFace.hitTest(convert(point, from: superview))
    case .terminal, .editor: return super.hitTest(point)
    }
  }

  // 器がマウスを受けるのは透かしている間だけ。受けた押下とスクロールは何もせずに終える（親の view へ渡さない）。
  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
}
