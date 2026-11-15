import AppKit

/// 頭——最初の行の上に置き、行と一緒に送る 1 枚の view。
extension RowListView {
  /// 頭を `header` にする（nil なら外す）。
  func setHeader(_ header: (any RowListHeader)?) {
    guard header !== self.header else { return }
    self.header?.removeFromSuperview()
    self.header = header
    if let header { addSubview(header) }
    headerDidChange()
  }

  /// 頭の中身が変わった——今の幅で高さを測り直し、変わっていれば行の位置を置き直す。頭が見えなくなるまで送っていれば、
  /// 見えている行が画面の同じ位置に残るように、高さの差だけ送る（頭が見えていれば送らない）。行を留めていれば（→
  /// `RowListAnchor`）、頭が見えていても、留める行を押した行の窓の中の高さへ送り直す。
  func headerDidChange() {
    let height = header.map { $0.height(fitting: bounds.width).rounded(.up) } ?? 0
    header?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
    guard height != headerHeight else { return }
    let top = visibleRect.minY
    let pastHeader = top > 0 && top >= headerHeight
    let shift = height - headerHeight
    headerHeight = height
    resizeDocument()
    if pastHeader { scroll(NSPoint(x: 0, y: top + shift)) }
    holdAnchor()
    layoutRows()
    updatePointer()
  }
}

/// 行の列の最初の行の上に置く頭（1 枚の view）。高さは中身と列の幅で決まる。中身が変わって高さが変わりうるときは、持ち主が
/// `RowList.headerDidChange` を呼ぶ（列の幅が変わったときは列が自分で測り直す）。
@MainActor
protocol RowListHeader: NSView {
  /// 幅 `width` に収めたときの高さ。
  func height(fitting width: CGFloat) -> CGFloat
}
