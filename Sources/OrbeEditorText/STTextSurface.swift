import AppKit
import OrbeEditorCore
import STTextView

/// `TextSurface` の STTextView 実装。スクロールビューにテキストビューを載せ、ガター・rendering
/// attribute・delegate・焦点・viewport をこの契約へ写す。undo は STTextView が自前で持つ（打鍵を
/// まとめる coalescing はビュー内部の undo manager にしか無い）。
///
/// 行の装備と強調の地は受動的な overlay 3 枚で描く（ガターの印・本文のインデント線／丸点／URL 下線・強調の地）。
/// 上流に行ごとの描画の拡張点が無いので、公開の view と TextKit 2 の API だけで載せる——ただし強調の地だけは、選択の地の
/// 上・文字の下に出すために上流の本文の層の中へ差し込む（公開の口が無い。`installHighlightView`）。どれも寸法は viewport
/// （文書の全高にすると数万行で巨大な tiled layer になる）で、layout の収束とスクロールのたびに置き直す
/// ——片方だけでは速いスクロールで印が遅れ、編集で古くなる。
///
/// スクロールビューは面が組む——最終行を最上段までスクロールできる clip（`OverscrollClipView`）を documentView より先に
/// 据える（上流は documentView が入った時点の clip の bounds 変化を観測する）。縦スクローラーは出さない——位置は面の外の
/// スクロールバーとミニマップが担う。横はそのままで、様式はオーバーレイに固定する（OS の「常に表示」やマウスの有無で
/// 本文の下が削られない）。
@MainActor
final class STTextSurface: NSObject, TextSurface {
  /// 上端の余白を持つ器。スクロールビューの contentInsets は使わない——横に浮くガター（floating
  /// subview）が inset を無視して行番号だけ下へずれる（STTextView が FB21059465 として回避している）。
  private let container = SurfaceContainerView()
  private let scrollView: NSScrollView
  private let textView: SurfaceTextView
  private let marksView: LineMarksView
  private let decorationView: LineDecorationView
  private let highlightView: TextHighlightView
  private let groundView = GutterGroundView()
  private let clipView = OverscrollClipView()
  private var observers: [NSObjectProtocol] = []

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
    scrollView = NSScrollView()
    textView = SurfaceTextView()
    self.style = style
    marksView = LineMarksView(textView: textView, style: style.marks)
    decorationView = LineDecorationView(
      textView: textView, style: style.decorations, textColor: style.textColor)
    highlightView = TextHighlightView(textView: textView, style: style.highlights)
    super.init()
    // 上流の `scrollableTextView()` の設定を写す（縦スクローラーだけ出さない）。
    scrollView.contentView = clipView
    scrollView.clipsToBounds = true
    scrollView.wantsLayer = true
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = true
    scrollView.drawsBackground = false
    scrollView.scrollerStyle = .overlay
    scrollView.documentView = textView
    clipView.lastLineTop = { [weak self] in self?.lastLineTop }
    container.addSubview(scrollView)
    // clear にすると gutter も clear になり、NSVisualEffectView の地が敷かれない（器の veil が透ける）。
    textView.backgroundColor = .clear
    // 本文はガターの右端から始める（既定の 5pt の余白を持たない）。
    textView.textContainer.lineFragmentPadding = 0
    textView.highlightSelectedLine = false
    textView.showsInvisibleCharacters = false
    textView.textDelegate = self
    textView.onFocusChange = { [weak self] focused in
      guard let self else { return }
      highlightView.isFocused = focused
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
    // 装備の overlay は本文の層の下（本文・キャレット・選択の下に出る——選択の地が装備を覆う）。強調の地は本文の層の
    // 中の選択の層の直上。ガターの overlay はガターの subview で、印の列はガターの右端に錨を置く（上流は桁が増えると
    // ガターを右へ伸ばす）。
    textView.addSubview(decorationView, positioned: .below, relativeTo: nil)
    installHighlightView()
    textView.gutterView?.addSubview(groundView, positioned: .below, relativeTo: nil)
    textView.gutterView?.addSubview(marksView)
    // overlay の矩形は clip view の矩形の関数——スクロール（bounds）と窓の live resize（frame。上流はその間
    // layout を止める）の両方で置き直す。
    clipView.postsBoundsChangedNotifications = true
    clipView.postsFrameChangedNotifications = true
    let relayout: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.layoutOverlays() }
    }
    observers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map {
      NotificationCenter.default.addObserver(
        forName: $0, object: clipView, queue: nil, using: relayout)
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: nil
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.scrollView.scrollerStyle = .overlay }
      })
    applyParagraphStyle()
    textView.text = text
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// 強調の地を上流の本文の層（テキスト view の子のうち、面が置いた overlay 以外の唯一の子）の中の、選択の層（その
  /// 最初の子）の直上へ差し込む。上流は選択の層の子を layout のたびに空にするので、その中には入れない。上流はキャレットの
  /// view を同じ層へ足すが並べ替えないので、差し込んだ位置は保たれる。構造が違えば黙って別の位置に置かない。
  private func installHighlightView() {
    let content = textView.subviews.filter { $0 !== decorationView }
    guard content.count == 1, let layer = content.first, let selection = layer.subviews.first
    else {
      assertionFailure("STTextView の本文の層の構造が想定と違う: \(textView.subviews)")
      return
    }
    layer.addSubview(highlightView, positioned: .above, relativeTo: selection)
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

  func setHighlights(_ ranges: [NSRange], for kind: TextHighlightKind) {
    highlightView.ranges[kind] = ranges
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

  /// 行の中心を clip の中央へ置き（`anchor`）、それから列が横に見えるところまで寄せる（縦はもう見えているので動かない）。
  func scrollToCenter(_ offset: Int) {
    let location = min(max(0, offset), length)
    anchor(location) { frame in
      frame.midY - self.clipView.bounds.height / 2
    }
    textView.scrollRangeToVisible(NSRange(location: location, length: 0))
  }

  /// 行頭の行を、その高さの `hiddenFraction` ぶん隠して先頭へ。横位置は保つ。
  func scroll(toTop offset: Int, hiddenFraction: CGFloat) {
    let fraction = min(max(0, hiddenFraction), 1)
    anchor(min(max(0, offset), length)) { frame in
      frame.minY + fraction * frame.height
    }
  }

  /// オフセットの行の矩形から決めた y へ clip を置き、layout を落ち着かせる。TextKit 2 は layout していない行の位置を推定で持ち、
  /// layout が進むたびに推定を直す——遠くへ飛ぶと、置いた直後の layout で狙った行が動き（先頭の行がずれる）、上流は
  /// viewport の行片を置いた後に末尾を layout し直すので、画面の行片の view が古い位置に残る（本文と、矩形から描く
  /// 装備・強調の地・クリックの当たりが食い違う）。その行だけを layout して位置を得て（viewport の relocate は重いので
  /// 使わない）、置き直しと layout を行の位置が動かなくなるまで繰り返す（推定が揺れ続けても止まるよう回数に上限を置く）。
  private func anchor(_ offset: Int, y: (CGRect) -> CGFloat) {
    let x = clipView.bounds.minX
    let manager = textView.textContentManager
    guard let location = manager.location(manager.documentRange.location, offsetBy: offset)
    else { return }
    let layoutManager = textView.textLayoutManager
    for _ in 0..<Self.anchorPasses {
      layoutManager.ensureLayout(for: NSTextRange(location: location))
      layoutManager.ensureLayout(
        for: NSTextRange(location: layoutManager.documentRange.endLocation))
      guard let frame = VisibleLines(textView: textView).line(containing: offset)?.frame else {
        return
      }
      let target = min(max(0, y(frame)), clipView.maximumY)
      guard abs(clipView.bounds.minY - target) > 0.25 || abs(clipView.bounds.minX - x) > 0.25
      else { return }
      clipView.scroll(to: NSPoint(x: x, y: target))
      scrollView.reflectScrolledClipView(clipView)
      textView.needsLayout = true
      textView.layoutSubtreeIfNeeded()
    }
  }

  /// 推定の揺れを落ち着かせる置き直しの上限。
  private static let anchorPasses = 4

  /// 最終行（末尾の空行を含む）の上端。
  private var lastLineTop: CGFloat? {
    VisibleLines(textView: textView).lastLine()?.frame.minY
  }

  func scrollToVisible(_ range: NSRange) {
    textView.scrollRangeToVisible(range)
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
    let body = NSRect(
      x: visible.minX, y: visible.minY, width: max(0, visible.width - gutterWidth),
      height: visible.height)
    decorationView.frame = body.offsetBy(dx: gutterWidth, dy: 0)
    // 強調の地は本文の層（container の座標。ガターの右から）の子。
    highlightView.frame = body
    for overlay in [decorationView, highlightView] as [NSView] {
      overlay.setBoundsOrigin(body.origin)
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
      delegate?.surfaceDidChangeViewport(self)
    }
  }

  /// clip の上端にある行の矩形（行片の単位——末尾の空行も 1 行）から viewport を出す。可視行数は clip の高さから
  /// （上端の overscroll で縮めない）。上端に layout が無ければ nil（次の layout の通知で出し直す）。
  private func measureViewport() -> TextViewport? {
    let clip = clipView.bounds
    guard clip.height > 0,
      let line = VisibleLines(textView: textView).line(atY: max(0, clip.minY))
    else { return nil }
    let frame = line.frame
    let hidden = frame.height > 0 ? min(max((clip.minY - frame.minY) / frame.height, 0), 1) : 0
    let pixel = 1 / (textView.window?.backingScaleFactor ?? 1)
    return TextViewport(
      firstVisible: line.start, hiddenFraction: hidden,
      visibleLines: clip.height / style.lineHeight,
      clipsRight: textView.frame.maxX - clip.maxX > pixel)
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
    highlightView.needsDisplay = true
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
