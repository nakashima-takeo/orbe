import AppKit

/// 一覧の器の行の列の源。行の組は器の今の中身で、列が読み直すまでの問いと操作は、描いている中身で同一性に直してから器へ
/// 渡す（中身が差し替わってから列が読み直すまでの間に押しても、見えている行に当たる）。キーと押下の意味は器が決める。
final class EditorItemListSource: RowListSource {
  /// 描いている中身の行の組（閉じている間・開く前は空）。
  struct Rows {
    let rows: (any EditorItemListRows)?

    var count: Int { rows?.count ?? 0 }
  }

  private weak var itemList: EditorItemList?

  init(itemList: EditorItemList) {
    self.itemList = itemList
  }

  var rows: Rows { Rows(rows: itemList?.content?.rows) }

  func rowCount(in rows: Rows) -> Int { rows.count }

  func makeRowView() -> EditorItemListRowView { EditorItemListRowView(frame: .zero) }

  func show(_ row: Int, of rows: Rows, in view: EditorItemListRowView, emoji: NSFont?) {
    guard let all = rows.rows else { return }
    view.show(all.row(at: row), selectable: all.id(at: row) != nil, emoji: emoji)
  }

  func row(of selection: AnyHashable, in rows: Rows) -> Int? {
    rows.rows?.index(of: selection)
  }

  func prepareRows(for appearance: NSAppearance) {
    EditorItemListRowView.prepare(for: appearance)
  }

  var wantsFocus: Bool { itemList?.wantsFocus ?? false }

  func focusRequestDidApply() { itemList?.focusRequestDidApply() }

  func focusDidChange(_ focused: Bool) {
    if !focused { itemList?.focusDidLeave() }
  }

  func perform(_ key: RowListKey, in rows: Rows) {
    itemList?.perform(key.action)
  }

  func keyDidRelease() {}

  func click(_ row: Int, in rows: Rows) {
    guard let id = rows.rows?.id(at: row) else { return }
    itemList?.commit(id)
  }

  /// 行のクリックで器は閉じるので、2 度目の押下は器に届かない。
  func doubleClick(_ row: Int, in rows: Rows) {}

  func press(_ row: Int, control: Int, in rows: Rows) -> RowListAnchor<AnyHashable>? {
    guard let id = rows.rows?.id(at: row) else { return nil }
    itemList?.press(id)
    return nil
  }

  func select(_ row: Int, in rows: Rows) {
    guard let id = rows.rows?.id(at: row) else { return }
    itemList?.select(id)
  }
}
