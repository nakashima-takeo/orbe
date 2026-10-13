import SwiftUI

/// 件名の並び（主の番号・タイトル・続く札と補足）。縮むのはタイトルが先で、タイトルが最小幅まで縮んだら、続く札を
/// `dropOrder` の小さい順にまるごと外す（途中で切った札は読めないため）。札でない補足（待ちの理由）は外さず、残りの幅で
/// 末尾を省略する。件名で最も大事なのはタイトルで、札に押されて消えてはいけない。主の番号は縮めない。
struct TaskSubjectLayout: Layout {
  let spacing: CGFloat
  let titleMinWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    let widths = self.widths(subviews, available: proposal.width ?? .infinity)
    let ideal =
      widths.reduce(0) { $0 + $1 } + spacing * CGFloat(max(0, widths.count { $0 > 0 } - 1))
    return CGSize(width: proposal.width ?? ideal, height: proposal.height ?? height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    for (index, width) in widths(subviews, available: bounds.width).enumerated() {
      subviews[index].place(
        at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: width, height: bounds.height))
      if width > 0 { x += width + spacing }
    }
  }

  private func widths(_ subviews: Subviews, available: CGFloat) -> [CGFloat] {
    widths(
      ideals: subviews.map { $0.sizeThatFits(.unspecified).width },
      dropOrders: subviews.map { $0[SubjectDropOrder.self] }, available: available)
  }

  /// 子ごとの幅（0 は出さない）。子は番号・タイトル・続く札と補足の順で、`dropOrders` は札の外す順（札でない子は
  /// nil）。番号は理想の幅、札は理想の幅か 0、タイトルは最小幅を下回らない範囲で残りを取り、札でない補足はその残り。
  func widths(ideals: [CGFloat], dropOrders: [Int?], available: CGFloat) -> [CGFloat] {
    guard ideals.count >= 2 else { return ideals }
    let items = ideals.indices.dropFirst(2).filter { ideals[$0] > 0 }
    let gap = { (width: CGFloat) in width > 0 ? width + self.spacing : 0 }
    let space = available - gap(ideals[0])
    // 列そのものが最小幅より狭ければ、タイトルは列に収まる幅で末尾を省略する（はみ出して切らない）。
    let titleFloor = min(ideals[1], titleMinWidth, max(0, space))
    var kept = items
    func badgesWidth() -> CGFloat {
      kept.filter { dropOrders[$0] != nil }.reduce(0) { $0 + gap(ideals[$1]) }
    }
    // 札を外しても足りない間、外す順の早い札から外す（補足は 0 まで縮められるので数えない）。
    while titleFloor + badgesWidth() > space,
      let drop = kept.filter({ dropOrders[$0] != nil })
        .min(by: { dropOrders[$0]! < dropOrders[$1]! })
    {
      kept.removeAll { $0 == drop }
    }
    let rest = kept.reduce(0) { $0 + gap(ideals[$1]) }
    let title = min(ideals[1], max(titleFloor, space - rest))
    var free = space - title - badgesWidth()
    var widths = ideals.indices.map { $0 < 2 ? ideals[$0] : 0 }
    widths[1] = title
    for index in kept {
      if dropOrders[index] != nil {
        widths[index] = ideals[index]
      } else {
        widths[index] = max(0, min(ideals[index], free - spacing))
        free -= gap(widths[index])
      }
    }
    return widths
  }
}

/// 件名に続く札を外す順（小さいほど先に外す）。nil は札でない補足で、外さずに縮める。
private struct SubjectDropOrder: LayoutValueKey {
  static let defaultValue: Int? = nil
}

extension View {
  /// 件名に続く札。幅 0 を言われたらまるごと出さない（途中で切らない）。
  func subjectBadge(dropOrder: Int) -> some View {
    frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .clipped()
      .layoutValue(key: SubjectDropOrder.self, value: dropOrder)
  }
}
