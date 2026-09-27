import AppKit
import OrbeEditorCore

/// 今の面（自分で俯瞰を描かない面）の俯瞰——本体の右のミニマップと縦スクロールバー、本体に重ねる影、本体の上のポインタ
/// の見張り（つまみの見え隠れ）、スクロールの状態の記憶。pane はこの持ち物を、今の面の文書を見せている間だけ結ぶ（自分で
/// 俯瞰を描く面の文書では結ばず、部品は隠れる）。
@MainActor
final class EditorAppKitOverview: NSObject {
  let minimap: EditorMinimapView
  let scrollbar: EditorScrollbarView
  let shadow: EditorScrollShadowView
  /// 本体の上のポインタを見る tracking area（載せる view に置く）。
  private(set) var tracking: NSTrackingArea?
  /// 結んだ文書。
  private(set) weak var document: EditorDocument?
  /// 最後に見たスクロールの状態（変化でつまみを見せる）。文書を結び直すと捨てる。
  private var lastScrollState: ScrollState?

  init(style: TextSurfaceStyle) {
    minimap = EditorMinimapView(style: style)
    scrollbar = EditorScrollbarView(style: style.overview)
    shadow = EditorScrollShadowView(style: style.overview)
    super.init()
    shadow.isHidden = true
  }

  /// 部品を載せる（テキスト面はこれらの下に入る）。
  func install(in view: NSView) {
    for part in [minimap, scrollbar, shadow] as [NSView] {
      part.autoresizingMask = []
      view.addSubview(part)
    }
  }

  /// 文書に結ぶ（nil なら外して隠す）。
  func bind(_ document: EditorDocument?) {
    self.document = document
    lastScrollState = nil
    minimap.bind(document)
    scrollbar.bind(document)
    shadow.isHidden = document == nil
    updateShadow()
  }

  /// 検索の一致と語の出現。
  var decorations: OverviewDecorations {
    get { minimap.decorations }
    set {
      minimap.decorations = newValue
      scrollbar.decorations = newValue
    }
  }

  func viewportDidChange() {
    guard document != nil else { return }
    minimap.refresh()
    scrollbar.refresh()
    noteScrollState()
    updateShadow()
  }

  func hunksOrSelectionDidChange() {
    guard document != nil else { return }
    minimap.refresh()
    scrollbar.refresh()
  }

  func textDidChange(_ edits: [VersionedEdit]) {
    guard document != nil else { return }
    minimap.textDidChange(edits)
    scrollbar.refresh()
    noteScrollState()
  }

  func rolesDidChange(_ ranges: IndexSet) {
    guard document != nil else { return }
    minimap.rolesDidChange(ranges)
  }

  /// 部品を置く。`surface` はテキスト面の矩形（影を重ねる）。
  func layout(surface: NSRect, minimap minimapRect: NSRect, scrollbar scrollbarRect: NSRect) {
    minimap.frame = minimapRect
    scrollbar.frame = scrollbarRect
    // 影は本文の上だけ（VS Code では不透明のミニマップが上に重なって影を隠す。Orbe のミニマップは地が透けるので、
    // 影をミニマップに掛けない）。
    shadow.frame = surface
    updateShadow()
  }

  /// 本体の上のポインタの見張りを置き直す（ドラッグ中も出入りを受ける——つまみを押したまま本体の外で離せば、つまみが
  /// 消える）。
  func updateTracking(in view: NSView, body: NSRect) {
    if let tracking { view.removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: body, options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag],
      owner: self)
    view.addTrackingArea(area)
    tracking = area
  }

  @objc func mouseEntered(with event: NSEvent) {
    scrollbar.hovering = true
  }

  @objc func mouseExited(with event: NSEvent) {
    scrollbar.hovering = false
  }

  /// スクロールの状態（縦横の位置・見えている大きさ・行数）が変わればスクロールバーのつまみを見せる——VS Code の
  /// スクロールの状態が変わったときと同じく、スクロールに限らず窓の大きさの変化・改行・横スクロールでも現れる。
  /// 文書を結んだ後の最初の測定では出さない。
  private func noteScrollState() {
    guard let document else { return }
    let viewport = document.surface.viewport
    let state = ScrollState(
      firstLine: document.viewportLines.first, visibleLines: viewport.visibleLines,
      lineCount: document.text.lineCount, hiddenColumns: viewport.hiddenColumns,
      visibleColumns: viewport.visibleColumns)
    defer { lastScrollState = state }
    guard let last = lastScrollState, last != state else { return }
    scrollbar.didScroll()
  }

  /// スクロールの状態（`noteScrollState`）。
  private struct ScrollState: Equatable {
    let firstLine: CGFloat
    let visibleLines: CGFloat
    let lineCount: Int
    let hiddenColumns: CGFloat
    let visibleColumns: CGFloat
  }

  /// 本体の上端の影（先頭行が隠れている）とミニマップ左の影（本文が右に続く）。
  private func updateShadow() {
    guard let document else { return }
    let viewport = document.surface.viewport
    shadow.showsTop = viewport.firstVisible > 0 || viewport.hiddenFraction > 0
    shadow.minimapEdge = viewport.clipsRight ? minimap.frame.minX - shadow.frame.minX : nil
  }
}
