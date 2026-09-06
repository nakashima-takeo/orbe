import SwiftUI

/// 同 worktree のタブを連ねる器（§5 Tab 契約）。地 tabSegBg・radius xs・クリップを器が持ち、
/// 中身（バー・セル）は app 層が合成する。1 枚でも器 1 本（＝単独タブの絵）。
struct DSTabSegment<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 0) { content() }
      .frame(maxHeight: .infinity)
      .background(RoundedRectangle(cornerRadius: Theme.Radius.xs).fill(Color.theme.tabSegBg))
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))
  }
}

/// セグメント左端の worktree 識別バー（縦 fill）。ジェスチャは app 層が付ける。
struct DSSegmentBar: View {
  /// バー幅（DS 部品の固有寸法。幅計算 `StatusTabLayout` もこれを読む）。
  static let width: CGFloat = 3
  let color: Color

  var body: some View {
    Rectangle()
      .fill(color)
      .frame(width: Self.width)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
  }
}

#Preview("DSTabSegment") {
  HStack(spacing: Chrome.tabGap) {
    DSTabSegment {
      DSSegmentBar(color: Color.theme.worktreeBar[WorktreeColor.index(forKey: "orbe")])
      DSTab(title: "src/renderer", active: true, stateGlyph: .working, divided: true)
      DSTab(title: "libghostty", stateGlyph: .waiting, divided: true)
      DSTab(title: "tests", divided: true)
    }
    DSTabSegment { DSTab(title: "docs/spec", stateGlyph: .done) }
  }
  .padding(Chrome.tabRowPad)
  .frame(height: Chrome.tabRowHeight)
  .background(Color.theme.tabRowBg)
  .padding(Theme.Space.phrase)
  .background(Color.theme.bgBase)
}
