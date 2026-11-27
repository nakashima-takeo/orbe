import AppKit

/// 改行で伸びるメッセージ欄（ソース管理のコミットメッセージ・レビューのポップアップの全体へのコメント）の枠。スクロールバーはいつも
/// overlay——AppKit は推奨の型が変わるたびに setter で各枠をその型（マウスをつないだ Mac では legacy）へ戻し、
/// legacy のバーは 10 行を越えた途端に字の幅を狭めて折り返しを変える。
final class MessageScrollView: NSScrollView {
  override var scrollerStyle: NSScroller.Style {
    get { super.scrollerStyle }
    // swiftlint:disable:next unused_setter_value
    set { super.scrollerStyle = .overlay }
  }
}

/// メッセージ欄のテキスト面。空のときプレースホルダを描き、焦点の出入りを知らせる。`onCommit` があれば修飾の無い ↵ はそれを
/// 求め、ほかの改行の命令（`onCommit` が無ければ ↵ も）は `\n` を入れる。字体・1 行のときの欄の高さ・行の高さ・左右の余白は
/// 欄ごとに渡す。
final class MessageTextView: NSTextView {
  /// 欄の寸法。
  struct Metrics {
    var font: NSFont
    /// 1 行のときの欄の高さ（行の高さ ＋ 上下の余白）。
    var height: CGFloat
    /// 行の高さ（どの行も同じ。字は行の上下の中央）。nil なら字体の既定の行の高さ。
    var lineHeight: CGFloat?
    /// 字の左右の余白。
    var leading: CGFloat
    var trailing: CGFloat
  }

  var placeholder = "" {
    didSet { if placeholder != oldValue, string.isEmpty { needsDisplay = true } }
  }
  var onFocus: ((Bool) -> Void)?
  var onWindow: (() -> Void)?
  /// 修飾の無い ↵ を押した（何も入れない）。無ければ ↵ は改行。
  var onCommit: (() -> Void)?
  /// 変換中の字が変わった（変換が始まった・変わった・終わった。終われば空）。
  var onComposition: ((String) -> Void)?
  /// 変換中でない esc を押した。無ければ esc は標準の命令のまま。
  var onEscape: (() -> Void)?
  /// 解釈中の押下（`interpretKeyEvents` が同期に呼ぶ命令へ添える）。改行の命令は ↵ と ⇧↵ で同じなので、押下から読み分ける。
  private var interpreting: NSEvent?
  /// 手で組んだ文字の系の根（テキスト面はこれを持たないので、自分で持つ）。
  private let storage: NSTextStorage
  /// 高さの問いだけに使う組み（同じ文字の系に足した 2 つ目のレイアウト。表示の組みに触れずに、問われた幅で組む）。
  private let measuring: NSTextContainer
  private let metrics: Metrics
  /// 行の高さ。
  private let textLineHeight: CGFloat
  /// 1 行のときに欄の高さが `metrics.height` になる上下の余白。
  private let verticalInset: CGFloat
  /// 欄の文の属性（字体・段落・色）。
  private let attributes: [NSAttributedString.Key: Any]
  /// 行の高さを決めた欄の行の組み方（2 つの組みの両方に当てる。組みは持ち主を弱く持つので、ここで持つ）。
  private let lineLayout: MessageLineLayout?

  /// 寸法 `metrics` の欄。
  init(metrics: Metrics) {
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = false
    container.lineFragmentPadding = 0
    let layout = NSLayoutManager()
    layout.addTextContainer(container)
    let storage = NSTextStorage()
    storage.addLayoutManager(layout)
    let measuring = NSTextContainer(size: .zero)
    measuring.lineFragmentPadding = 0
    let measuringLayout = NSLayoutManager()
    measuringLayout.backgroundLayoutEnabled = false
    measuringLayout.addTextContainer(measuring)
    storage.addLayoutManager(measuringLayout)
    self.storage = storage
    self.measuring = measuring
    self.metrics = metrics
    let natural = layout.defaultLineHeight(for: metrics.font)
    textLineHeight = metrics.lineHeight ?? natural
    verticalInset = (metrics.height - textLineHeight) / 2
    var attributes: [NSAttributedString.Key: Any] = [
      .font: metrics.font, .foregroundColor: Theme.Color.textPrimary,
    ]
    if let lineHeight = metrics.lineHeight {
      // 字の無い行（空の欄・末尾の改行の後）の高さは段落の行の高さで決まる。字の在る行は組み方が決める。
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = lineHeight
      paragraph.maximumLineHeight = lineHeight
      attributes[.paragraphStyle] = paragraph
      let lineLayout = MessageLineLayout(lineHeight: lineHeight, font: metrics.font)
      layout.delegate = lineLayout
      measuringLayout.delegate = lineLayout
      self.lineLayout = lineLayout
    } else {
      lineLayout = nil
    }
    self.attributes = attributes
    super.init(frame: .zero, textContainer: container)
    font = metrics.font
    textColor = Theme.Color.textPrimary
    insertionPointColor = Theme.Color.accentPrimary
    drawsBackground = false
    isRichText = false
    allowsUndo = true
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isVerticallyResizable = true
    isHorizontallyResizable = false
    // 上限を開けないと、テキスト面は見えている枠より高くならず、10 行を越えた分へスクロールできない。
    maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textContainerInset = NSSize(width: 0, height: verticalInset)
    defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
    typingAttributes = attributes
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  /// 行の左右の余白（テキストコンテナの左右は同じ余白しか持てないので、左はコンテナの原点で動かす）。
  override var textContainerOrigin: NSPoint {
    NSPoint(x: metrics.leading, y: super.textContainerOrigin.y)
  }

  /// 表示の組みの幅の持ち主はテキスト面の枠だけ（高さの問いは別の組みで答える）。
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    textContainer?.containerSize = NSSize(
      width: max(0, newSize.width - metrics.leading - metrics.trailing),
      height: CGFloat.greatestFiniteMagnitude)
  }

  /// 幅 `width` で中身が収まる高さ（`maxLines` 行まで）。表示の組みには触れず、問われた幅だけで決まる。組むのは `maxLines`
  /// 行の分まで（長い貼り付けでも、問いのたびに全文を組まない）。
  func fittingHeight(width: CGFloat, maxLines: Int) -> CGFloat {
    let limit = textLineHeight * CGFloat(maxLines)
    guard let layout = measuring.layoutManager else { return metrics.height }
    let size = NSSize(
      width: max(0, width - metrics.leading - metrics.trailing), height: .greatestFiniteMagnitude)
    if measuring.containerSize != size { measuring.containerSize = size }
    layout.ensureLayout(
      forBoundingRect: NSRect(x: 0, y: 0, width: size.width, height: limit), in: measuring)
    let used = max(layout.usedRect(for: measuring).height, textLineHeight)
    return min(used, limit) + verticalInset * 2
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { DispatchQueue.main.async { [weak self] in self?.onWindow?() } }
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocus?(true) }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocus?(false) }
    return resigned
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
    let placeholderAttributes: [NSAttributedString.Key: Any] = [
      .font: metrics.font, .foregroundColor: Theme.Color.editorTertiary,
    ]
    let origin = textContainerOrigin
    let line = NSAttributedString(string: placeholder, attributes: placeholderAttributes)
    // 行の高さを決めた欄では、字を行の上下の中央に置く（字の在る行の組み方と同じ位置）。
    let top = lineLayout.map { $0.baseline - metrics.font.ascender } ?? 0
    line.draw(
      with: NSRect(
        x: origin.x, y: origin.y + top, width: max(0, bounds.width - origin.x - metrics.trailing),
        height: textLineHeight - top),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  override func keyDown(with event: NSEvent) {
    interpreting = event
    defer { interpreting = nil }
    super.keyDown(with: event)
  }

  /// ↵ と ⇧↵（と pane が取らない修飾の組）の命令。`onCommit` があれば修飾の無い ↵ だけがコミットで（押し続けたキーリピートは
  /// 捨て、押した瞬間だけをコミットの合図にする）、ほか（押下の無い合成の命令を含む）は改行——押し間違いは軽い側に倒す。
  /// `onCommit` が無ければ、どれも改行。
  override func insertNewline(_ sender: Any?) {
    if let onCommit, let press = interpreting,
      press.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
      press.specialKey == .carriageReturn || press.specialKey == .enter
    {
      if !press.isARepeat { onCommit() }
      return
    }
    super.insertNewline(sender)
  }

  /// 欄の文字列の全体。置き換えた文字列は欄の属性（`attributes`）をとる（テキスト面の既定では、置き換えた文字列は前の文字列の
  /// 先頭の文字の属性を引き継ぐ。前の文字列が代わりの字体で組まれていると、その字体が残り、高さの問いと表示とで末尾の改行の
  /// 後の行の高さが食い違う）。
  override var string: String {
    get { super.string }
    set {
      super.string = newValue
      storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
    }
  }

  /// キーの命令。esc の命令（`cancelOperation:`）は、変換中でなく `onEscape` があれば、それを求める。ほかは、テキスト面の
  /// 標準の処理のまま（テキスト面は esc の命令を処理しないので、次の responder へ渡る）。
  override func doCommand(by selector: Selector) {
    if selector == #selector(NSResponder.cancelOperation(_:)), let onEscape, !hasMarkedText() {
      onEscape()
      return
    }
    super.doCommand(by: selector)
  }

  /// ⌃↵。標準の行区切り（U+2028）はメッセージに見えない字を入れるので、改行にする。
  override func insertLineBreak(_ sender: Any?) {
    super.insertNewline(sender)
  }

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
    contentHeightMayHaveChanged()
    reportComposition()
  }

  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    reportComposition()
  }

  override func unmarkText() {
    super.unmarkText()
    reportComposition()
  }

  /// 変換中なら確定する（IME の変換も終わらせる）。確定した字は、返る前に `textDidChange` でメッセージへ入る。
  func confirmComposition() {
    guard hasMarkedText() else { return }
    unmarkText()
    inputContext?.discardMarkedText()
  }

  /// 変換中の字を知らせる（IME の確定の `insertText` は `didChangeText` で拾う）。
  private func reportComposition() {
    onComposition?(hasMarkedText() ? (string as NSString).substring(with: markedRange()) : "")
  }

  /// 中身を外から差し替える（コミット後に空にした・別の窓で打った）。差し替えは undo に積まず、欄の取り消しの履歴も捨てる
  /// ——古い履歴は今の文と食い違い、⌘Z が文の外の範囲を戻そうとする。
  func replaceDiscardingUndo(with message: String) {
    breakUndoCoalescing()
    string = message
    undoManager?.removeAllActions()
    contentHeightMayHaveChanged()
  }

  /// 中身の高さが変わりうる（打鍵・貼り付け・取り消し・IME の確定・外からの差し替え）。SwiftUI は欄の大きさ
  /// （`sizeThatFits`）を入力が変わったときだけ聞き直し、AppKit の中の打鍵では聞き直さないので、表現の view から知らせる。
  /// 幅の変化は SwiftUI の提案が変わるので、ここでは知らせない。
  private func contentHeightMayHaveChanged() {
    enclosingScrollView?.invalidateIntrinsicContentSize()
  }
}

/// 行の高さを決めた欄の行の組み方。字の在るどの行の断片も決めた高さにし、主の字体の字（上端から下端まで）を行の上下の中央に
/// 置く。段落の行の高さの上限は、代わりの字体の字（タイ文字など）が伸ばす行の高さを止めないので、断片をここで決める。
private final class MessageLineLayout: NSObject, NSLayoutManagerDelegate {
  let lineHeight: CGFloat
  /// 行の上端から baseline までの距離。
  let baseline: CGFloat

  init(lineHeight: CGFloat, font: NSFont) {
    self.lineHeight = lineHeight
    baseline = (lineHeight - (font.ascender - font.descender)) / 2 + font.ascender
  }

  // swiftlint:disable:next function_parameter_count
  func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
    lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
    baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer,
    forGlyphRange glyphRange: NSRange
  ) -> Bool {
    lineFragmentRect.pointee.size.height = lineHeight
    lineFragmentUsedRect.pointee.size.height = lineHeight
    baselineOffset.pointee = baseline
    return true
  }
}
