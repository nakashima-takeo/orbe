import SwiftUI

private enum BrowserToolbarRole {
  case fixed
  case url
  case peekPill
}

private struct BrowserToolbarRoleKey: LayoutValueKey {
  static let defaultValue: BrowserToolbarRole = .fixed
}

extension View {
  /// ツールバーの URL 欄スロットとして登録する。
  func browserToolbarURL() -> some View {
    layoutValue(key: BrowserToolbarRoleKey.self, value: .url)
  }

  /// ツールバーの全面めくり案内ピルとして登録する。狭幅で幅 0 を提案された際に 0×0 へ畳む契約を内包する。
  func browserToolbarPeekPill() -> some View {
    frame(
      minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
      alignment: .leading
    )
    .clipped()
    .layoutValue(key: BrowserToolbarRoleKey.self, value: .peekPill)
  }
}

/// 戻る・進む・再読込・全面切替の 4 ボタンを左詰めで優先確保し、残余幅へ URL 欄を配る 1 パス配置。
/// 全面めくり案内ピルは URL 欄へ `urlPeekMinWidth` 以上を確保できる幅でのみ表示し、狭幅では 0×0 に畳むことで
/// 単一ビューツリーを保ち `BrowserURLTextField` の構造的アイデンティティを壊さない。
struct BrowserToolbarLayout: Layout {
  let spacing: CGFloat
  let urlMarginX: CGFloat
  let urlPeekMinWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
      let widths = subviews.map { subview -> CGFloat in
        let width = subview.sizeThatFits(.unspecified).width
        return subview[BrowserToolbarRoleKey.self] == .url ? width + urlMarginX * 2 : width
      }
      let total = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
      return CGSize(width: total, height: proposal.height ?? height)
    }
    return CGSize(width: proposedWidth, height: proposal.height ?? height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let roles = subviews.map { $0[BrowserToolbarRoleKey.self] }
    let widths = resolveWidths(subviews: subviews, roles: roles, available: bounds.width)
    var x = bounds.minX
    for (index, subview) in subviews.enumerated() {
      let width = widths[index]
      switch roles[index] {
      case .fixed:
        subview.place(
          at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
          proposal: ProposedViewSize(width: width, height: bounds.height))
        x += width + spacing
      case .url:
        if width > 0 {
          x += urlMarginX
          subview.place(
            at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: width, height: bounds.height))
          x += width + urlMarginX + spacing
        } else {
          subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .zero)
        }
      case .peekPill:
        if width > 0 {
          subview.place(
            at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: width, height: bounds.height))
          x += width + spacing
        } else {
          subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .zero)
        }
      }
    }
  }

  private func resolveWidths(
    subviews: Subviews, roles: [BrowserToolbarRole], available: CGFloat
  ) -> [CGFloat] {
    let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
    var widths = Array(repeating: CGFloat(0), count: subviews.count)
    var fixedTotal: CGFloat = 0
    var fixedCount = 0
    var urlIndex: Int?
    var pillIndex: Int?
    for (index, role) in roles.enumerated() {
      switch role {
      case .fixed:
        widths[index] = ideals[index]
        fixedTotal += ideals[index]
        fixedCount += 1
      case .url:
        urlIndex = index
      case .peekPill:
        pillIndex = index
      }
    }
    guard let urlIndex else { return widths }
    let baseGaps = spacing * CGFloat(fixedCount)
    let marginTotal = urlMarginX * 2
    if let pillIndex {
      let pillWidth = ideals[pillIndex]
      let urlWithPill = available - fixedTotal - pillWidth - marginTotal - (baseGaps + spacing)
      if pillWidth > 0, urlWithPill >= urlPeekMinWidth {
        widths[pillIndex] = pillWidth
        widths[urlIndex] = urlWithPill
        return widths
      }
    }
    widths[urlIndex] = max(0, available - fixedTotal - marginTotal - baseGaps)
    return widths
  }
}
