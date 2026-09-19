import AppKit
import OrbeEditorCore
import STTextView

/// `TextSurface` の STTextView 実装。スクロールビューにテキストビューを載せ、ガター・rendering
/// attribute・delegate・焦点・viewport をこの契約へ写す。undo は STTextView が自前で持つ（打鍵を
/// まとめる coalescing はビュー内部の undo manager にしか無い）。
///
/// 行の装備と検索の一致は受動的な overlay 3 枚で描く（ガターの印・本文のインデント線／丸点／URL 下線・一致の地）。
/// 上流に行ごとの描画の拡張点が無いので、公開の view と TextKit 2 の API だけで載せる。どれも寸法は viewport
/// （文書の全高にすると数万行で巨大な tiled layer になる）で、layout の収束とスクロールのたびに置き直す
/// ——片方だけでは速いスクロールで印が遅れ、編集で古くなる。
///
/// 縦スクローラーは出さない——位置は面の外の俯瞰（ミニマップの帯と印の列）が担う。横はそのまま。
@MainActor
final class STTextSurface: NSObject, TextSurface {
  /// 上端の余白を持つ器。スクロールビューの contentInsets は使わない——横に浮くガター（floating
  /// subview）が inset を無視して行番号だけ下へずれる（STTextView が FB21059465 として回避している）。
  private let container = SurfaceContainerView()
  private let scrollView: NSScrollView
  private let textView: SurfaceTextView
  private let marksView: LineMarksView
  private let decorationView: LineDecorationView
  private let searchView: SearchHighlightView
  private let groundView = GutterGroundView()
  private var clipObservers: [NSObjectProtocol] = []

  var view: NSView { container }
  var responder: NSView { textView }
  weak var delegate: TextSurfaceDelegate?
  private(set) var visibleRange = NSRange(location: 0, length: 0)
  /// 見えている範囲（本文の言葉）。overlay を置き直すたびに実際の行の矩形から出し直す（上端に layout が無い
  /// 一瞬は前の値を保つ）。
  private(set) var viewport = TextViewport.empty

  private let style: TextSurfaceStyle
  /// インデントの単位（文書が検出して押す）。インデント線の段と、タブの表示幅（単位の桁数）を決める。
  private var indentUnit = IndentUnit.fallback

  var onOpenLink: ((URL) -> Void)? {
    get { textView.onOpenLink }
    set { textView.onOpenLink = newValue }
  }

  init(style: TextSurfaceStyle, text: String) {
    scrollView = SurfaceTextView.scrollableTextView()
    // swiftlint:disable:next force_cast
    textView = scrollView.documentView as! SurfaceTextView
    self.style = style
    marksView = LineMarksView(textView: textView, style: style.marks)
    decorationView = LineDecorationView(
      textView: textView, style: style.decorations, textColor: style.textColor)
    searchView = SearchHighlightView(
      textView: textView, color: style.decorations.searchMatchColor,
      radius: style.decorations.searchMatchRadius)
    super.init()
    container.addSubview(scrollView)
    scrollView.hasVerticalScroller = false
    // clear にすると gutter も clear になり、NSVisualEffectView の地が敷かれない（器の veil が透ける）。
    textView.backgroundColor = .clear
    // 本文はガターの右端から始める（既定の 5pt の余白を持たない）。
    textView.textContainer.lineFragmentPadding = 0
    textView.highlightSelectedLine = false
    textView.showsInvisibleCharacters = false
    textView.textDelegate = self
    textView.onFocusChange = { [weak self] focused in
      guard let self else { return }
      delegate?.surface(self, focusDidChange: focused)
    }
    textView.addPlugin(
      ViewportPlugin { [weak self] range in
        guard let self else { return }
        visibleRange = range.map { NSRange($0, in: self.textView.textContentManager) } ?? NSRange()
        layoutOverlays()
        delegate?.surfaceDidLayoutViewport(self)
      })
    apply(style)
    // 本文の overlay は contentView の下（本文・キャレット・選択の下に出る）。一致の地は装備の上。ガターの
    // overlay はガターの subview で、印の列はガターの右端に錨を置く（上流は桁が増えるとガターを右へ伸ばす）。
    textView.addSubview(decorationView, positioned: .below, relativeTo: nil)
    textView.addSubview(searchView, positioned: .above, relativeTo: decorationView)
    textView.gutterView?.addSubview(groundView, positioned: .below, relativeTo: nil)
    textView.gutterView?.addSubview(marksView)
    // overlay の矩形は clip view の矩形の関数——スクロール（bounds）と窓の live resize（frame。上流はその間
    // layout を止める）の両方で置き直す。
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.contentView.postsFrameChangedNotifications = true
    clipObservers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map {
      NotificationCenter.default.addObserver(
        forName: $0, object: scrollView.contentView, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.layoutOverlays() }
      }
    }
    applyParagraphStyle()
    textView.text = text
  }

  deinit {
    for observer in clipObservers { NotificationCenter.default.removeObserver(observer) }
  }

  var text: String { textView.text ?? "" }

  private var length: Int {
    NSRange(textView.textContentManager.documentRange, in: textView.textContentManager).length
  }

  func substring(in range: NSRange) -> String {
    guard let textRange = NSTextRange(range, in: textView.textContentManager) else { return "" }
    return textView.textContentManager.attributedString(in: textRange)?.string ?? ""
  }

  func applyHighlights(_ spans: [HighlightSpan], in ranges: IndexSet) {
    let length = self.length
    for range in ranges.rangeView {
      let clamped = NSRange(range).clamped(to: length)
      if clamped.length > 0 { textView.removeRenderingAttribute(.foregroundColor, range: clamped) }
    }
    for span in spans {
      let clamped = span.range.clamped(to: length)
      guard clamped.length > 0, let color = style.roleColors[span.role] else { continue }
      textView.addRenderingAttributes([.foregroundColor: color], range: clamped)
    }
  }

  func markUndoBoundary() {
    textView.breakUndoCoalescing()
  }

  func setLineMarks(_ spans: LineMarkSpans) {
    marksView.spans = spans
  }

  func setSearchHighlights(_ ranges: [NSRange]) {
    searchView.ranges = ranges
  }

  /// タブの表示幅は単位の桁数——モデル（タブは 1 段）と描画が一致し、空白だけの行の線（桁幅から置く）がタブで
  /// 書かれた隣の行の線と揃う。
  func setIndentUnit(_ unit: Int) {
    guard unit != indentUnit else { return }
    indentUnit = unit
    applyParagraphStyle()
    decorationView.indentUnit = unit
  }

  var selectedRange: NSRange {
    get { textView.textSelection }
    set { textView.textSelection = newValue }
  }

  /// 上流の find と同じ順で着地させる——viewport の外なら relocate → layout（`scrollRangeToVisible` が持つ）、
  /// それから実際に layout された矩形の中心を clip の中央へ（先頭・末尾で clamp）。推定の文書高は使わない。
  func scrollToCenter(_ offset: Int) {
    let manager = textView.textContentManager
    guard let location = manager.location(manager.documentRange.location, offsetBy: offset) else {
      return
    }
    textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
    let range = NSTextRange(location: location)
    textView.textLayoutManager.ensureLayout(for: range)
    guard let frame = textView.textLayoutManager.textSegmentFrame(in: range, type: .standard) else {
      return
    }
    let clip = scrollView.contentView
    let limit = max(0, textView.frame.height - clip.bounds.height)
    let y = min(max(0, frame.midY - clip.bounds.height / 2), limit)
    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
    scrollView.reflectScrolledClipView(clip)
  }

  /// 地は器が本文の下に、`GutterGroundView` がガターの上に敷く（上流のガターは本文の上に浮き、横スクロールで
  /// 本文がその下を通る——上に地が無いと行番号と字が重なる）。同じ矩形を二度塗らないので透過の濃度が揃う。
  func setGround(_ color: NSColor) {
    container.ground = color
    groundView.color = color
  }

  /// overlay を viewport の矩形に置き直して描き直し、viewport を出し直して外へ告げる。本文の overlay は frame を
  /// 可視矩形に、bounds の原点を text container 基準の同じ点に置く——x も y も container の座標がそのまま view の
  /// 座標になり、描く側が座標を手で引かない。ガターの overlay は x が局所（列の右端に錨）、y が文書（上流は行番号を
  /// 文書の y に置く）。
  private func layoutOverlays() {
    let visible = textView.visibleRect
    let gutterWidth = textView.gutterView?.frame.width ?? 0
    for overlay in [decorationView, searchView] as [NSView] {
      overlay.frame = NSRect(
        x: visible.minX + gutterWidth, y: visible.minY, width: max(0, visible.width - gutterWidth),
        height: visible.height)
      overlay.setBoundsOrigin(NSPoint(x: visible.minX, y: visible.minY))
      overlay.needsDisplay = true
    }
    if let gutter = textView.gutterView {
      // ガターの地は可視矩形（clip view。テキスト view の高さに依らない）を文書の下端（ガターの高さ）で
      // 切ったぶん。器はその矩形を塗らない。
      let clip = scrollView.contentView.bounds
      let ground = CGRect(x: 0, y: clip.minY, width: gutter.bounds.width, height: clip.height)
        .intersection(gutter.bounds)
      groundView.frame = ground
      container.groundHole = NSRect(
        x: 0, y: ground.minY - clip.minY + style.topInset, width: ground.width,
        height: ground.height)
      marksView.frame = NSRect(
        x: gutter.bounds.width - style.marks.gutterWidth, y: visible.minY,
        width: style.marks.gutterWidth, height: visible.height)
      marksView.setBoundsOrigin(NSPoint(x: 0, y: visible.minY))
      marksView.needsDisplay = true
    }
    // 指カーソルの矩形は ⌘ を押している間だけ張る。上流はスクロール・編集で捨てないので、見える行が変わる
    // たび（layout の収束と、viewport を動かさない小さなスクロールの両方）に捨て直す（⌘ の押下・解放は
    // `flagsChanged` が持つ）。
    if NSEvent.modifierFlags.contains(.command) {
      textView.window?.invalidateCursorRects(for: textView)
    }
    if let current = measureViewport(), current != viewport {
      viewport = current
      delegate?.surfaceDidScroll(self)
    }
  }

  /// clip の可視矩形（overscroll の負は 0 に clamp）の上端にある行の矩形から viewport を出す。上端に layout が
  /// 無ければ nil（次の layout の通知で出し直す）。
  private func measureViewport() -> TextViewport? {
    var clip = scrollView.contentView.bounds
    if clip.minY < 0 {
      clip.size.height = max(0, clip.height + clip.minY)
      clip.origin.y = 0
    }
    guard clip.height > 0,
      let fragment = textView.textLayoutManager.textLayoutFragment(
        for: CGPoint(x: 0, y: clip.minY))
    else { return nil }
    let frame = fragment.layoutFragmentFrame
    let hidden = frame.height > 0 ? min(max((clip.minY - frame.minY) / frame.height, 0), 1) : 0
    return TextViewport(
      firstVisible: NSRange(fragment.rangeInElement, in: textView.textContentManager).location,
      hiddenFraction: hidden, visibleLines: clip.height / style.lineHeight)
  }

  /// STTextView の置換は undo 登録と `didChangeTextIn` を 1 回ずつ通す（`text` の代入は undo 登録を
  /// 切るので使わない）。置換後の選択は本文の外を指しうるので、元のキャレット位置を新しい長さに収めて置く。
  ///
  /// 変換中（marked text）は置換の**前**に畳む。STTextView 2.4.1 時点: 本文の置換で marked range を捨てず、
  /// 古い本文を指したまま残った range を次の変換操作で force-unwrap する（本文が短くなればクラッシュ、
  /// 長ければ無関係な位置が削れる）。畳むのは 2 つで 1 組——input context に `discardMarkedText()` で
  /// 変換セッションを捨てさせ（これだけでは `hasMarkedText` が消えない）、クライアント側の marked range は
  /// `unmarkText()` で消す。同じ force-unwrap は undo / redo で本文が動くときにも残る（上流の欠陥。ここでは
  /// 塞いでいない）。
  func replaceAll(with text: String) {
    textView.inputContext?.discardMarkedText()
    textView.unmarkText()
    let caret = textView.textSelection.location
    textView.replaceCharacters(in: textView.textLayoutManager.documentRange, with: text)
    textView.textSelection = NSRange(location: min(caret, length), length: 0)
  }

  /// 行高の倍率と、タブの表示幅（単位の桁数）。上流は既存の本文にも段落スタイルを打ち直す。
  private func applyParagraphStyle() {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = style.lineHeight / Self.naturalLineHeight(of: style.font)
    paragraph.tabStops = []
    paragraph.defaultTabInterval = CGFloat(indentUnit) * style.font.cellWidth
    textView.defaultParagraphStyle = paragraph
  }

  private func apply(_ style: TextSurfaceStyle) {
    textView.font = style.font
    textView.textColor = style.textColor
    textView.insertionPointColor = style.caretColor
    textView.caretSize = style.caretSize
    container.topInset = style.topInset
    textView.showsLineNumbers = true
    if let gutter = textView.gutterView {
      gutter.font = style.gutterFont
      gutter.textColor = style.gutterTextColor
      // 行番号は幅 `gutterWidth` の中に右寄せで収まり、その右に印の列が続く。
      gutter.insets = STRulerInsets(
        leading: 0, trailing: style.gutterTrailingInset + style.marks.gutterWidth)
      gutter.minimumThickness = style.gutterWidth + style.marks.gutterWidth
      gutter.drawSeparator = false
      gutter.highlightSelectedLine = false
    }
  }

  /// フォントの自然な行高（TextKit が行フラグメントに与える、丸めた高さ）。行高の固定値をこれで割った
  /// 倍率を渡す。
  private static func naturalLineHeight(of font: NSFont) -> CGFloat {
    NSLayoutManager().defaultLineHeight(for: font)
  }
}

extension STTextSurface: @preconcurrency STTextViewDelegate {
  func textView(
    _ textView: STTextView, didChangeTextIn affectedCharRange: NSTextRange,
    replacementString: String
  ) {
    let range = NSRange(affectedCharRange, in: textView.textContentManager)
    decorationView.needsDisplay = true
    searchView.needsDisplay = true
    marksView.needsDisplay = true
    delegate?.surface(
      self, didChange: TextEdit(range: range, replacementLength: replacementString.utf16.count))
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    delegate?.surfaceDidChangeSelection(self)
  }

  func textViewInsertionPointView(_ textView: STTextView, frame: CGRect)
    -> (any STInsertionPointIndicatorProtocol)?
  {
    CaretIndicatorView(frame: frame, size: style.caretSize, color: style.caretColor)
  }
}
