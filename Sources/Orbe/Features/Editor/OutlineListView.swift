import AppKit
import SwiftUI

/// アウトラインの中身の器（pane が 1 つ持ち、閉じても捨てない）: 上に絞り込みの入力欄（出している間だけ）、下に行の列。
/// 入力欄を AppKit の同じ器に置くのは、列で打った最初の 1 字を、その打鍵のうちに入力欄へ渡し直すため——入力欄を出して
/// 焦点を移し、同じ出来事を入力欄の編集器へ送るので、IME も最初の字から働く（日本語の見出しで絞り込める）。
final class OutlineListView: NSView {
  let outline: EditorOutline
  let scrollView: RowList<OutlineListSource>
  let field: OutlineFilterField
  private let source: OutlineListSource

  init(outline: EditorOutline) {
    self.outline = outline
    let source = OutlineListSource(outline: outline)
    self.source = source
    scrollView = RowList(source: source, rowHeight: Theme.Layout.editorRow)
    field = OutlineFilterField()
    super.init(frame: .zero)
    source.container = self
    field.isHidden = true
    field.onChange = { [weak self] text in self?.outline.setFilterText(text) }
    field.onCommand = { [weak self] command in self?.fieldCommand(command) ?? false }
    addSubview(field)
    addSubview(scrollView)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  /// 入力欄を出しているかと字（model の写し）を置き直す。欄で打っている間は欄の字が model を先に書くので、違うのは
  /// model から変わったとき（畳んだ・文書を替えた）だけ。
  func update(filterShown: Bool, text: String) {
    if field.text != text { field.text = text }
    guard filterShown == field.isHidden else { return }
    field.isHidden = !filterShown
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let fieldHeight = field.isHidden ? 0 : OutlineFilterField.rowHeight
    field.frame = NSRect(x: 0, y: 0, width: bounds.width, height: fieldHeight)
    scrollView.frame = NSRect(
      x: 0, y: fieldHeight, width: bounds.width, height: max(0, bounds.height - fieldHeight))
  }

  /// 列で打った文字を入力欄で受け直す（入力欄を出して焦点を移し、同じ出来事を入力欄の編集器へ送る）。
  func redirectTyping(_ event: NSEvent) {
    outline.showFilter()
    update(filterShown: true, text: outline.filterText)
    layoutSubtreeIfNeeded()
    guard let window, window.makeFirstResponder(field.textField),
      let editor = field.textField.currentEditor()
    else { return }
    editor.keyDown(with: event)
  }

  /// 入力欄のキー: ↑↓ と Enter は行の操作、Esc は絞り込みを解いて行へ戻る。
  private func fieldCommand(_ command: Selector) -> Bool {
    switch command {
    case #selector(NSResponder.moveUp(_:)): outline.moveSelection(by: -1)
    case #selector(NSResponder.moveDown(_:)): outline.moveSelection(by: 1)
    case #selector(NSResponder.insertNewline(_:)): outline.activateSelection()
    case #selector(NSResponder.cancelOperation(_:)):
      outline.clearFilter()
      update(filterShown: false, text: "")
      window?.makeFirstResponder(scrollView.list)
    default: return false
    }
    return true
  }
}

/// アウトラインの行の列の源。行は model から番号で引き、操作は model へ渡す。列で打った文字は器が入力欄で受け直す。
final class OutlineListSource: RowListSource {
  typealias RowView = OutlineRowView
  typealias Selection = EditorOutline.Selection

  let outline: EditorOutline
  weak var container: OutlineListView?

  init(outline: EditorOutline) {
    self.outline = outline
  }

  var rowCount: Int { outline.rowCount }

  func makeRowView() -> OutlineRowView {
    OutlineRowView(frame: NSRect(x: 0, y: 0, width: 0, height: Theme.Layout.editorRow))
  }

  func show(_ row: Int, in view: OutlineRowView, emoji: NSFont?) {
    view.show(outline.row(at: row), emoji: emoji)
  }

  func row(of selection: Selection) -> Int? { outline.row(of: selection) }

  func prepareRows(for appearance: NSAppearance) {
    OutlineRowView.prepare(for: appearance)
  }

  var wantsFocus: Bool { false }
  func focusRequestDidApply() {}
  func focusDidChange(_ focused: Bool) {}

  /// 修飾の無い（⇧だけは可）文字の打鍵を入力欄へ回す。Space は開閉なので回さない。
  func takeTyping(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .function])
    guard flags.isEmpty, event.specialKey == nil, let characters = event.characters,
      !characters.isEmpty, characters != " ",
      characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { return false }
    container?.redirectTyping(event)
    return true
  }

  func perform(_ key: RowListKey) -> Bool {
    switch key {
    case .up: outline.moveSelection(by: -1)
    case .down: outline.moveSelection(by: 1)
    case .left: outline.moveLeft()
    case .right: outline.moveRight()
    case .space: outline.toggleSelection()
    case .enter: outline.activateSelection()
    case .home: outline.selectEdge(last: false)
    case .end: outline.selectEdge(last: true)
    case .escape:
      guard outline.isFilterShown else { return false }
      outline.clearFilter()
      container?.update(filterShown: false, text: "")
    case .pageUp, .pageDown: return false
    }
    return true
  }

  func click(_ row: Int, x: CGFloat) {
    outline.click(row: row) { OutlineRowView.isOnChevron(x, depth: $0) }
  }

  func doubleClick(_ row: Int, x: CGFloat) {
    outline.doubleClick(row: row) { OutlineRowView.isOnChevron(x, depth: $0) }
  }

  func select(_ row: Int) { outline.select(row: row) }
}

/// アウトラインの器を SwiftUI に載せる。読む値（行の版・選択・入力欄の有無・絵文字の字体）を model から読んで渡す。
struct OutlineListHost: NSViewRepresentable {
  let list: OutlineListView
  let rowsVersion: Int
  let selection: EditorOutline.Selection?
  let filterShown: Bool
  let filterText: String
  @Environment(\.chromeFontResolver) private var fontResolver
  @Environment(\.localization) private var l10n

  func makeNSView(context: Context) -> OutlineListView { list }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: OutlineListView, context: Context)
    -> CGSize?
  {
    proposal.replacingUnspecifiedDimensions()
  }

  func updateNSView(_ list: OutlineListView, context: Context) {
    list.field.setPlaceholder(l10n.string(.editorOutlineFilterPlaceholder))
    list.update(filterShown: filterShown, text: filterText)
    list.scrollView.update(
      rowsVersion: rowsVersion, selection: selection,
      reveal: list.outline.revealsCentered ? .center : .nearest, emoji: fontResolver.emojiFont,
      wantsFocus: false)
  }
}

/// 絞り込みの入力欄（見出しの下の 1 段）。見た目は検索パネルの入力欄と同じ様式（地 sunk .35・枠 hairline .10 角 3、焦点で
/// 枠 accent .55 角 5）。
final class OutlineFilterField: NSView, NSTextFieldDelegate {
  /// 段の高さ（欄 ＋ 下の余白）。
  static let rowHeight: CGFloat = Theme.Layout.editorSearchField + 6
  private static let inset = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)

  let textField = NSTextField()
  var onChange: (String) -> Void = { _ in }
  /// 入力欄のキー（`doCommandBy`）。扱ったら true。
  var onCommand: (Selector) -> Bool = { _ in false }
  private let box = CALayer()
  private var focused = false

  var text: String {
    get { textField.stringValue }
    set { textField.stringValue = newValue }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(box)
    textField.isBordered = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.font = Theme.Typography.editorSearchField
    textField.textColor = Theme.Color.textPrimary
    textField.lineBreakMode = .byClipping
    textField.cell?.isScrollable = true
    textField.delegate = self
    addSubview(textField)
    NotificationCenter.default.addObserver(
      self, selector: #selector(editingChanged), name: NSControl.textDidBeginEditingNotification,
      object: textField)
    NotificationCenter.default.addObserver(
      self, selector: #selector(editingChanged), name: NSControl.textDidEndEditingNotification,
      object: textField)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  /// プレースホルダを置く（言語が変わったときだけ置き直す）。
  func setPlaceholder(_ text: String) {
    guard textField.placeholderAttributedString?.string != text else { return }
    textField.placeholderAttributedString = NSAttributedString(
      string: text,
      attributes: [
        .font: Theme.Typography.editorSearchField, .foregroundColor: Theme.Color.editorTertiary,
      ])
  }

  override func layout() {
    super.layout()
    let rect = NSRect(
      x: Self.inset.left, y: Self.inset.top,
      width: max(0, bounds.width - Self.inset.left - Self.inset.right),
      height: Theme.Layout.editorSearchField)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.frame = rect
    CATransaction.commit()
    let height = textField.intrinsicContentSize.height
    textField.frame = NSRect(
      x: rect.minX + Theme.Space.step, y: rect.midY - height / 2,
      width: max(0, rect.width - Theme.Space.step * 2), height: height)
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      box.backgroundColor = EditorStyle.sunk(0.35).cgColor
      box.borderWidth = Theme.Stroke.hairline
      box.borderColor =
        focused
        ? Theme.Color.accentPrimary.withAlphaComponent(0.55).cgColor
        : EditorStyle.hairline(0.10).cgColor
      box.cornerRadius = focused ? 5 : Theme.Radius.xs
    }
  }

  @objc private func editingChanged() {
    let editing = textField.currentEditor() != nil
    guard editing != focused else { return }
    focused = editing
    needsDisplay = true
  }

  func controlTextDidChange(_ notification: Notification) {
    onChange(textField.stringValue)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    onCommand(selector)
  }
}
