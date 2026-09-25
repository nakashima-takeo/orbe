import AppKit
import OrbeEditorCore
import STTextView

/// `TextSurface` の STTextView 実装。スクロールビューにテキストビューを載せ、行番号の列・rendering
/// attribute・delegate・焦点・viewport をこの契約へ写す。undo は STTextView が自前で持つ（打鍵を
/// まとめる coalescing はビュー内部の undo manager にしか無い）。
///
/// 構文の色は窓（上流が layout した範囲）にだけ置く（→ `SyntaxColorWindow`）。行番号の列は上流のガターを使わず、
/// スクロールビューの左隣に自前で置く（→ `LineNumbersView`）——上流のガターは画面が動くたびに全部の行番号を作り直し、
/// 文書の先頭から段落を数える。
///
/// 行番号の列と、行の装備と強調の地の overlay 2 枚（本文のインデント線／丸点／URL 下線・強調の地）は受動的に描く。
/// 上流に行ごとの描画の拡張点が無いので、公開の view と TextKit 2 の API だけで載せる——ただし強調の地だけは、選択の地の
/// 上・文字の下に出すために上流の本文の層の中へ差し込む（公開の口が無い。`installHighlightView`）。どれも寸法は viewport
/// （文書の全高にすると数万行で巨大な tiled layer になる）で、layout の収束とスクロールのたびに置き直す
/// ——片方だけでは速いスクロールで印が遅れ、編集で古くなる。上流は responsive scrolling を使わないので、clip の bounds の
/// 通知は同期で届き、本文と同じコマで動く。
///
/// スクロールビューは面が組む——最終行を最上段までスクロールできる clip（`OverscrollClipView`）を documentView より先に
/// 据える（上流は documentView が入った時点の clip の bounds 変化を観測する）。縦スクローラーは出さない——位置は面の外の
/// スクロールバーとミニマップが担う。横はそのままで、様式はオーバーレイに固定する（OS の「常に表示」やマウスの有無で
/// 本文の下が削られない）。
@MainActor
final class STTextSurface: NSObject, TextSurface {
  /// 上端の余白を空けて行番号の列とスクロールビューを並べる器。
  private let container = SurfaceContainerView()
  private let scrollView: NSScrollView
  private let textView: SurfaceTextView
  private let numbersView: LineNumbersView
  private let decorationView: LineDecorationView
  private let highlightView: TextHighlightView
  private let clipView = OverscrollClipView()
  private var observers: [NSObjectProtocol] = []

  var view: NSView { container }
  var responder: NSView { textView }
  weak var delegate: TextSurfaceDelegate?
  private let colors: SyntaxColorWindow
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
    numbersView = LineNumbersView(textView: textView, style: style)
    decorationView = LineDecorationView(
      textView: textView, style: style.decorations, textColor: style.textColor)
    highlightView = TextHighlightView(textView: textView, style: style.highlights)
    colors = SyntaxColorWindow(textView: textView, colors: style.roleColors)
    super.init()
    colors.roles = { [weak self] in self?.roles(in: $0) ?? [] }
    numbersView.source = self
    installScrollView()
    textView.backgroundColor = .clear
    // 本文は行番号の列の右端から始める（既定の 5pt の余白を持たない）。
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
        if let range { colors.layoutDidChange(range) }
        layoutOverlays()
      })
    apply(style)
    // 装備の overlay は本文の層の下（本文・キャレット・選択の下に出る——選択の地が装備を覆う）。強調の地は本文の層の
    // 中の選択の層の直上。
    textView.addSubview(decorationView, positioned: .below, relativeTo: nil)
    installHighlightView()
    // overlay の矩形は clip view の矩形の関数——スクロール（bounds）と窓の live resize（frame。上流はその間
    // layout を止める）の両方で置き直す。
    clipView.postsBoundsChangedNotifications = true
    clipView.postsFrameChangedNotifications = true
    let relayout: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated {
        self?.colors.scrollDidChange()
        self?.layoutOverlays()
      }
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

  /// 上流の `scrollableTextView()` の設定を写し（縦スクローラーだけ出さない）、器に行番号の列と並べる。
  private func installScrollView() {
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
    container.addSubview(numbersView)
    container.scrollTarget = scrollView
    container.column = numbersView
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

  private func roles(in range: NSRange) -> [HighlightSpan] {
    delegate?.surface(self, rolesIn: range) ?? []
  }

  func markUndoBoundary() {
    textView.breakUndoCoalescing()
  }

  func setLineMarks(_ spans: LineMarkSpans) {
    numbersView.marksView.spans = spans
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

  var caretLocation: Int { textView.caretLocation }

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

  /// overlay と行番号の列を viewport の矩形に置き直して描き直し、viewport を出し直して外へ告げる。本文の overlay は
  /// frame を可視矩形に、bounds の原点を text container 基準の同じ点に置く——x も y も container の座標がそのまま view の
  /// 座標になり、描く側が座標を手で引かない。行番号の列は y だけ文書の座標に合わせる。
  private func layoutOverlays() {
    let visible = textView.visibleRect
    for overlay in [decorationView, highlightView] as [NSView] {
      overlay.frame = visible
      overlay.setBoundsOrigin(visible.origin)
      overlay.needsDisplay = true
    }
    numbersView.follow(clipView.bounds)
    // 指カーソルの矩形は ⌘ を押している間だけ張る。上流はスクロール・編集で捨てないので、見える行が変わる
    // たび（layout の収束と、viewport を動かさない小さなスクロールの両方）に捨て直す（⌘ の押下・解放は
    // `flagsChanged` が持つ）。
    if NSEvent.modifierFlags.contains(.command) {
      textView.window?.invalidateCursorRects(for: textView)
    }
    clipView.updateBlankArea()
    if let current = measureViewport(), current != viewport {
      viewport = current
      delegate?.surfaceDidChangeViewport(self)
    }
  }

  /// clip の上端にある行の矩形（行片の単位——末尾の空行も 1 行）から viewport を出す。可視行数は clip の高さから
  /// （上端の overscroll で縮めない）。上端に layout が無ければ nil（次の layout の通知で出し直す）。
  private func measureViewport() -> TextViewport? {
    let clip = clipView.bounds
    guard clip.height > 0 else { return nil }
    let cell = style.font.cellWidth
    var viewport = TextViewport(
      firstVisible: 0, hiddenFraction: 0, visibleLines: clip.height / style.lineHeight,
      hiddenColumns: clip.minX / cell, visibleColumns: clip.width / cell)
    // 空の文書に TextKit 2 は layout fragment を作らない。行は 1 つ（空行）で、見えている範囲はその先頭。
    guard length > 0 else { return viewport }
    guard let line = VisibleLines(textView: textView).line(atY: max(0, clip.minY)) else {
      return nil
    }
    let frame = line.frame
    viewport.firstVisible = line.start
    viewport.hiddenFraction =
      frame.height > 0 ? min(max((clip.minY - frame.minY) / frame.height, 0), 1) : 0
    viewport.clipsRight =
      textView.frame.maxX - clip.maxX > 1 / (textView.window?.backingScaleFactor ?? 1)
    return viewport
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
    let edit = TextEdit(range: range, replacementLength: replacementString.utf16.count)
    decorationView.needsDisplay = true
    highlightView.needsDisplay = true
    numbersView.needsDisplay = true
    numbersView.marksView.needsDisplay = true
    delegate?.surface(self, didChange: edit)
    colors.textDidChange(edit, near: affectedCharRange.location)
    // 行数の桁が変われば列の幅が変わる。
    if numbersView.fittingWidth != numbersView.frame.width { container.needsLayout = true }
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

extension STTextSurface: LineSource {
  var lineCount: Int { delegate?.surfaceLineCount(self) ?? 1 }

  func line(containing offset: Int) -> Int {
    delegate?.surface(self, lineContaining: offset) ?? 0
  }

  func range(ofLine line: Int) -> NSRange {
    delegate?.surface(self, rangeOfLine: line) ?? NSRange(location: 0, length: length)
  }
}
