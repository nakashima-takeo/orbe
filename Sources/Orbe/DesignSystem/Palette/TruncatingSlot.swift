import SwiftUI

/// 縮みうる 1 行テキストの枠。末尾省略で読める形になる幅（先頭 1 文字＋…）があれば出し、無ければ
/// まったく出さない——`Text` は「…」を付ける幅も無いと、先頭の文字を「…」なしで途中まで描いてしまう。
/// 読める最小幅は、同じ描き方の見本（先頭 1 文字＋…）を見えない形で置いて測る。
/// 前後の余白は出すときだけ幅に足し、出さないときは余白ごと幅 0 になる。
struct TruncatingSlot<Content: View>: View {
  let text: String
  let leading: CGFloat
  let trailing: CGFloat
  let render: (String) -> Content

  init(
    _ text: String, leading: CGFloat = 0, trailing: CGFloat = 0,
    @ViewBuilder render: @escaping (String) -> Content
  ) {
    self.text = text
    self.leading = leading
    self.trailing = trailing
    self.render = render
  }

  var body: some View {
    TruncatingSlotLayout(leading: leading, trailing: trailing) {
      render(text).lineLimit(1).truncationMode(.tail)
      render(String(text.prefix(1)) + "…").lineLimit(1).fixedSize().hidden()
    }
    .clipped()
  }
}

/// 子 [本体, 見本]。余白を除いた幅が本体の全幅にも見本の幅にも満たなければ、余白ごと幅 0 で本体を
/// 描かない。
private struct TruncatingSlotLayout: Layout {
  let leading: CGFloat
  let trailing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let insets = leading + trailing
    let inner = ProposedViewSize(
      width: proposal.width.map { max(0, $0 - insets) }, height: proposal.height)
    let fits = content.sizeThatFits(inner)
    let shown = CGSize(width: fits.width + insets, height: fits.height)
    guard let width = inner.width, subviews.count == 2 else { return shown }
    let full = content.sizeThatFits(.unspecified).width
    let readable = subviews[1].sizeThatFits(.unspecified).width
    return width >= min(full, readable) ? shown : CGSize(width: 0, height: fits.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let width = max(0, bounds.width - leading - trailing)
    for subview in subviews {
      subview.place(
        at: CGPoint(x: bounds.minX + leading, y: bounds.minY),
        proposal: ProposedViewSize(width: width, height: bounds.height))
    }
  }
}
