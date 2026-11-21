import AppKit

/// 改行で伸びるメッセージ欄（ソース管理のコミットメッセージ・PR のパネルの全体へのコメント）の枠。スクロールバーはいつも
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
/// 求め、ほかの改行の命令（`onCommit` が無ければ ↵ も）は `\n` を入れる。
final class MessageTextView: NSTextView {
  var placeholder = "" {
    didSet { if placeholder != oldValue, string.isEmpty { needsDisplay = true } }
  }
  var onFocus: ((Bool) -> Void)?
  var onWindow: (() -> Void)?
  /// 修飾の無い ↵ を押した（何も入れない）。無ければ ↵ は改行。
  var onCommit: (() -> Void)?
  /// 変換中の字が変わった（変換が始まった・変わった・終わった。終われば空）。
  var onComposition: ((String) -> Void)?
  /// 解釈中の押下（`interpretKeyEvents` が同期に呼ぶ命令へ添える）。改行の命令は ↵ と ⇧↵ で同じなので、押下から読み分ける。
  private var interpreting: NSEvent?
  /// 手で組んだ文字の系の根（テキスト面はこれを持たないので、自分で持つ）。
  private var storage: NSTextStorage?
  /// 高さの問いだけに使う組み（同じ文字の系に足した 2 つ目のレイアウト。表示の組みに触れずに、問われた幅で組む）。
  private var measuring: NSTextContainer?

  private static let font = Theme.Typography.editorScmMessage
  private static let leading: CGFloat = 8
  /// 字の右の余白（欄ごとに指定する）。
  private var trailing: CGFloat = 0

  /// 字の右の余白を `trailing` にした欄（左は 8）。
  convenience init(trailing: CGFloat) {
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
    self.init(frame: .zero, textContainer: container)
    self.storage = storage
    self.measuring = measuring
    self.trailing = trailing
    font = Self.font
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
    textContainerInset = NSSize(width: 0, height: Self.verticalInset)
    typingAttributes = [.font: Self.font, .foregroundColor: Theme.Color.textPrimary]
  }

  /// 1 行の高さ。
  private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

  /// 1 行のときに高さ 26 になる上下の余白。
  private static let verticalInset = (Theme.Layout.editorScmMessage - lineHeight) / 2

  /// 行の左右の余白（左 8・右は欄ごとの `trailing`。テキストコンテナの左右は同じ余白しか持てないので、左はコンテナの原点で
  /// 動かす）。
  override var textContainerOrigin: NSPoint {
    NSPoint(x: Self.leading, y: super.textContainerOrigin.y)
  }

  /// 表示の組みの幅の持ち主はテキスト面の枠だけ（高さの問いは別の組みで答える）。
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    textContainer?.containerSize = NSSize(
      width: max(0, newSize.width - Self.leading - trailing),
      height: CGFloat.greatestFiniteMagnitude)
  }

  /// 幅 `width` で中身が収まる高さ（`maxLines` 行まで）。表示の組みには触れず、問われた幅だけで決まる。組むのは `maxLines`
  /// 行の分まで（長い貼り付けでも、問いのたびに全文を組まない）。
  func fittingHeight(width: CGFloat, maxLines: Int) -> CGFloat {
    let limit = Self.lineHeight * CGFloat(maxLines)
    guard let measuring, let layout = measuring.layoutManager else {
      return Theme.Layout.editorScmMessage
    }
    let size = NSSize(
      width: max(0, width - Self.leading - trailing), height: .greatestFiniteMagnitude)
    if measuring.containerSize != size { measuring.containerSize = size }
    layout.ensureLayout(
      forBoundingRect: NSRect(x: 0, y: 0, width: size.width, height: limit), in: measuring)
    let used = max(layout.usedRect(for: measuring).height, Self.lineHeight)
    return min(used, limit) + Self.verticalInset * 2
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
    let attributes: [NSAttributedString.Key: Any] = [
      .font: Self.font, .foregroundColor: Theme.Color.editorTertiary,
    ]
    let origin = textContainerOrigin
    let line = NSAttributedString(string: placeholder, attributes: attributes)
    line.draw(
      with: NSRect(
        x: origin.x, y: origin.y, width: max(0, bounds.width - origin.x - trailing),
        height: Self.lineHeight),
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
