import AppKit
import QuartzCore

/// 連の器: 端末面の上にエディター面を重ねた 2 層。端末面・その中の端末・エディター面は常に器いっぱいで、器は渡された開閉を
/// 両面の見せる・隠すとエディター面の濃さ（不透明度）へ写すだけ。開閉の正は窓（`WindowController`）が持ち、content の照合が渡す。
///
/// 端末面には連の materialize 済みのタブの端末を何枚でも差せ、見せるのはそのうち 1 枚。端末はどれも器の寸法に従う（エディターに
/// 覆われている間も、見せていない兄弟も）ので、開閉でも、連の中で見せる端末を替えても resize は起きない。
///
/// 開閉の動きはエディター面の濃さのフェード 1 つで、開閉の状態とクリックの届き先は動きを待たずに切り替わる。両面の可視と
/// 届き先は「開閉」と「動きの途中か」の 2 つから `applyFaces` が 1 か所で導く。
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

  /// エディターを開いているか。器は閉じた状態で生まれる。
  private(set) var isEditorOpen = false
  /// 開閉の動きの途中か。
  private(set) var isFading = false
  /// 最後に始めた動きの番号。置き換えられた動きの完了通知は、置き換えた直後に届くので、番号で見分けて捨てる。
  private var fadeGeneration = 0

  /// 動きを減らすか。システムの設定を写して変化に追従する（テストは直接決める）。真なら開閉は即時。
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
  }

  /// 端末を端末面から外す（既に別の器へ移っていれば、そちらからは外さない）。
  func remove(terminal: SurfaceScrollView) {
    terminals.removeAll { $0 === terminal }
    if shownTerminal === terminal { shownTerminal = nil }
    if terminal.superview === terminalFace { terminal.removeFromSuperview() }
  }

  /// 見せる端末を替える。開閉とエディターには触れない。
  func show(terminal: SurfaceScrollView) {
    guard terminal !== shownTerminal, terminals.contains(where: { $0 === terminal }) else {
      return
    }
    shownTerminal?.isHidden = true
    shownTerminal = terminal
    terminal.isHidden = false
  }

  override func layout() {
    super.layout()
    for view in [terminalFace, editorFace] + terminals where view.frame != bounds {
      view.frame = bounds
    }
    if editor.superview === editorFace, editor.frame != bounds { editor.frame = bounds }
  }

  // MARK: - 開閉

  /// 開閉を写す。同じ値なら何もしない（進行中の動きを切らない）。`animated` でも、器が窓に無い・器か祖先が隠れている・
  /// 動きを減らす設定なら即時。動きの途中で反転したら、今見えている濃さから逆へ続ける。
  func setEditorOpen(_ open: Bool, animated: Bool) {
    guard open != isEditorOpen else { return }
    isEditorOpen = open
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
    fade.duration = Theme.Motion.base
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

  /// 開閉と動きの途中かから、両面の可視とエディター面の濃さを写す。エディター面は開いているか動きの途中なら見せ、端末面は
  /// 閉じているか動きの途中なら見せる（開いている間は下の端末を描かない）。
  private func applyFaces() {
    editorFace.alphaValue = isEditorOpen ? 1 : 0
    editorFace.isHidden = !isEditorOpen && !isFading
    terminalFace.isHidden = isEditorOpen && !isFading
  }

  /// クリックの届き先は開閉に従う。閉じる途中のエディター面はまだ見えているが、クリックは下の端末面へ通す（エディター面がクリックを受けると、隠れる
  /// view に first responder が残る）。
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isEditorOpen, isFading else { return super.hitTest(point) }
    guard frame.contains(point) else { return nil }
    return terminalFace.hitTest(convert(point, from: superview))
  }
}
