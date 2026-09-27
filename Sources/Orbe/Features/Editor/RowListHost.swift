import AppKit
import SwiftUI

/// 持ち主が持つ行の列（`RowList`）を SwiftUI に載せる。読む値は載せる側が model から読んで渡し、値が変わったときだけ
/// 列を更新する。
struct RowListHost<Source: RowListSource>: NSViewRepresentable {
  let list: RowList<Source>
  let rowsVersion: Int
  let selection: Source.Selection?
  let reveal: RowListReveal
  let emoji: NSFont?
  let wantsFocus: Bool

  func makeNSView(context: Context) -> RowList<Source> { list }

  /// 与えられた大きさを埋める（AppKit の自動レイアウトで測らせない。更新のたびに部分木を測る手間がかかる）。
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: RowList<Source>, context: Context)
    -> CGSize?
  {
    proposal.replacingUnspecifiedDimensions()
  }

  func updateNSView(_ list: RowList<Source>, context: Context) {
    list.update(
      rowsVersion: rowsVersion, selection: selection, reveal: reveal, emoji: emoji,
      wantsFocus: wantsFocus)
  }
}
