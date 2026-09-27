import AppKit

/// 検索結果の列（NSTableView）。行は最大で約 2 万になるので、見えている行の view だけを作って使い回す——SwiftUI の遅延
/// スタックは結果が届くたびに全部の行を走査し、見えている行を組み直すので、1 回の更新が main を 8ms 以上占める。行は
/// `ProjectSearch` から番号で引いて描くだけで、選択・開閉・開くは model の操作を呼ぶ（表自身の選択は model の選択を写した
/// もので、表は自分で選択を動かさない）。
///
/// キー: ↑↓ は選択だけを動かし（開かない）、← → は折りたたみと親子の移動、Enter は開いてテキスト面へ、Esc は止めるか選択を
/// 外す。一致のシングルクリックは選んで開き（焦点は列に残る）、ダブルクリックは開いてテキスト面へ。
final class SearchResultsTableView: NSTableView {
  private let search: ProjectSearch
  /// 窓に載った（載る前に届いた焦点の要求をここで当てる）。
  var onWindow: () -> Void = {}

  init(search: ProjectSearch) {
    self.search = search
    super.init(frame: .zero)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
    column.resizingMask = .autoresizingMask
    addTableColumn(column)
    headerView = nil
    style = .plain
    rowSizeStyle = .custom
    intercellSpacing = .zero
    backgroundColor = .clear
    focusRingType = .none
    selectionHighlightStyle = .none
    allowsTypeSelect = false
    allowsMultipleSelection = false
    columnAutoresizingStyle = .uniformColumnAutoresizingStyle
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    onWindow()
    // 列が出た更新そのものには載せず、次の周回で済ませる。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      SearchResultRowView.prepare(for: effectiveAppearance)
    }
  }

  // MARK: - 焦点

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    guard super.becomeFirstResponder() else { return false }
    search.focusDidChange(.results, focused: true)
    return true
  }

  override func resignFirstResponder() -> Bool {
    guard super.resignFirstResponder() else { return false }
    search.focusDidChange(.results, focused: false)
    return true
  }

  // MARK: - マウス

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let index = row(at: convert(event.locationInWindow, from: nil))
    guard index >= 0, index < search.rowCount else { return }
    let id = search.row(at: index).id
    if event.clickCount >= 2 {
      search.doubleClick(id)
    } else {
      search.click(id)
    }
  }

  // MARK: - キー（表の既定の選択の動きは使わない）

  override func keyDown(with event: NSEvent) {
    interpretKeyEvents([event])
  }

  override func moveUp(_ sender: Any?) { search.moveSelection(by: -1) }
  override func moveDown(_ sender: Any?) { search.moveSelection(by: 1) }
  override func moveUpAndModifySelection(_ sender: Any?) { search.moveSelection(by: -1) }
  override func moveDownAndModifySelection(_ sender: Any?) { search.moveSelection(by: 1) }
  override func moveLeft(_ sender: Any?) { search.moveLeft() }
  override func moveRight(_ sender: Any?) { search.moveRight() }
  override func insertNewline(_ sender: Any?) { search.activateSelection() }
  override func cancelOperation(_ sender: Any?) { search.escapeInResults() }
}
