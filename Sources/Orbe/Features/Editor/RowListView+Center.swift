import AppKit

/// 行を中ほどへ送る口（浮く一覧が、開いたときの選択を列の高さの中ほどに見せる）。
extension RowListView {
  /// 行を、見えている範囲の高さの中ほどへ送る（文書の範囲に収める。錨を外す）。
  func scrollRowToCenter(_ row: Int) {
    guard row < rowCount else { return }
    releaseAnchor()
    let visible = visibleRect
    let top = rect(ofRow: row).midY - visible.height / 2
    scroll(NSPoint(x: 0, y: min(max(0, top), max(0, bounds.height - visible.height))))
  }
}
