import SwiftUI

/// `DSTabSegment` の固有寸法。generic な View 型は型引数なしに static を引けないため別に持つ。
enum DSTabSegmentMetrics {
  /// グループの枠が器の外側へはみ出す幅。行の合成（`StatusRowView`）はこの帯をスクロール内容に含める。
  static let frameOutset: CGFloat = Theme.Stroke.hairline
}

/// 同 worktree のタブを連ねる器（§5 Tab 契約）。地・角丸・枠・クリップを器が持ち、中身（バー・セル）は
/// app 層が合成する。単独タブは無彩色の地 tabSegBg のみ、グループ（2 枚以上の連）は tabGroupBg に
/// worktree 識別色を重ねた地と、器の外側 1px の識別色枠で囲む。
struct DSTabSegment<Content: View>: View {
  enum Kind: Equatable {
    /// 1 枚の連＝単独タブの絵。
    case single
    /// 2 枚以上の連。番号は `worktreeBar` と同じ worktree 識別色番号。
    case group(colorIndex: Int)
  }

  var kind: Kind = .single
  @ViewBuilder let content: () -> Content

  private var radius: CGFloat {
    switch kind {
    case .single: Theme.Radius.xs
    case .group: Theme.Radius.sm
    }
  }

  var body: some View {
    HStack(spacing: 0) { content() }
      .frame(maxHeight: .infinity)
      .background {
        switch kind {
        case .single:
          RoundedRectangle(cornerRadius: radius).fill(Color.theme.tabSegBg)
        case .group(let i):
          RoundedRectangle(cornerRadius: radius).fill(Color.theme.tabGroupBg)
          RoundedRectangle(cornerRadius: radius).fill(Color.theme.worktreeTint[i])
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: radius))
      // クリップの後に掛ける（前に置くと器の外へ出た枠ごと切られる）。
      .overlay {
        if case .group(let i) = kind {
          RoundedRectangle(cornerRadius: radius)
            .inset(by: -DSTabSegmentMetrics.frameOutset)
            .strokeBorder(
              Color.theme.worktreeFrame[i], lineWidth: DSTabSegmentMetrics.frameOutset)
        }
      }
  }
}

/// セグメント左端の worktree 識別バー（縦 fill）。番号は `DSTabSegment.Kind.group` と同じ worktree
/// 識別色番号。ジェスチャは app 層が付ける。
struct DSSegmentBar: View {
  /// バー幅（DS 部品の固有寸法。幅計算 `StatusTabLayout` もこれを読む）。
  static let width: CGFloat = 3
  let colorIndex: Int

  var body: some View {
    Rectangle()
      .fill(Color.theme.worktreeBar[colorIndex])
      .frame(width: Self.width)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
  }
}

#Preview("DSTabSegment") {
  HStack(spacing: Chrome.tabGap) {
    DSTabSegment(kind: .group(colorIndex: WorktreeColor.index(forKey: "orbe"))) {
      DSSegmentBar(colorIndex: WorktreeColor.index(forKey: "orbe"))
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
