import SwiftUI

/// 右端の縦ツールレール（ToolRail・幅 32）。ツリー / git / ブラウザ を切替える。
/// 非アクティブの git は未コミット変更がある時のみ橙ドットを右上に出す。ブラウザは dev サーバー
/// 未検出時にグレーアウト（減光）する。
struct ToolRailView: View {
  let tool: EditorTool
  /// 本体パネルの開閉。閉じている間はどのボタンも非アクティブ表示にする。
  let paneOpen: Bool
  /// 未コミット変更の有無（git ドットの点灯条件）。
  let hasChanges: Bool
  /// dev サーバー検出の有無（browser ボタンのグレーアウト条件）。未検出で減光する。
  let devServerRunning: Bool
  let onSelect: (EditorTool) -> Void

  var body: some View {
    VStack(spacing: 5) {
      RailButton(active: isActive(.tree), dot: nil) {
        TreeGlyph(color: iconColor(active: isActive(.tree)))
      } onTap: {
        onSelect(.tree)
      }
      RailButton(
        active: isActive(.git),
        dot: (!isActive(.git) && hasChanges) ? Color.theme.accentPrimary : nil
      ) {
        BranchGlyph(size: 12, color: iconColor(active: isActive(.git)))
      } onTap: {
        onSelect(.git)
      }
      // 未コミット変更ゼロはグレーアウト（押下は可能・changes が空表示になるだけ）。
      .opacity(hasChanges ? 1 : Theme.Opacity.disabled)
      RailButton(active: isActive(.browser), dot: nil) {
        GlobeGlyph(color: iconColor(active: isActive(.browser)))
      } onTap: {
        onSelect(.browser)
      }
      // dev サーバー未検出はグレーアウト（押下は可能・空状態「dev サーバー未起動」で開くだけ）。
      .opacity(devServerRunning ? 1 : Theme.Opacity.disabled)
      Spacer(minLength: 0)
      // ⌘/（本体パネルの開閉ヒント）は常駐レール最下部に 1 箇所だけ置く。
      Text(verbatim: "⌘/")
        .font(Font.theme.paneControl)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.bottom, 7)
    }
    .padding(.top, 7)
    .frame(width: 32)
    .frame(maxHeight: .infinity, alignment: .top)
    .overlay(alignment: .leading) {
      Rectangle().fill(Color.theme.surfaceInk.opacity(0.06)).frame(width: 1)
    }
  }

  /// アクティブ判定の一元定義。本体パネルが開いていて、かつ現在の選択ツールのときだけ真。
  private func isActive(_ t: EditorTool) -> Bool { paneOpen && tool == t }

  private func iconColor(active: Bool) -> Color {
    active ? Color.theme.tabActiveText : Color.theme.textMuted
  }
}

/// レールの1ボタン（22×22・角丸5・アクティブは textPrimary 反転面・右上ドット）。
private struct RailButton<Icon: View>: View {
  let active: Bool
  let dot: Color?
  @ViewBuilder let icon: Icon
  let onTap: () -> Void

  var body: some View {
    icon
      .frame(width: 22, height: 22)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(active ? Color.theme.textPrimary : Color.clear)
      )
      .overlay(alignment: .topTrailing) {
        if let dot {
          Circle().fill(dot).frame(width: 5, height: 5)
            .padding(.top, 2).padding(.trailing, 2)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture(perform: onTap)
  }
}

/// フォルダ形グリフ（TreeGlyph・viewBox16・stroke 1.3）。
struct TreeGlyph: View {
  var size: CGFloat = 12
  let color: Color

  var body: some View {
    TreeGlyphShape()
      .stroke(color, style: StrokeStyle(lineWidth: 1.3 * size / 16, lineJoin: .round))
      .frame(width: size, height: size)
  }
}

struct TreeGlyphShape: Shape {
  func path(in rect: CGRect) -> Path {
    let k = rect.width / 16
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * k, y: rect.minY + y * k)
    }
    let r = 1 * k
    var path = Path()
    // 左辺の途中から時計回り。角丸（r1）はタンジェント弧、タブの切り欠きは直線。
    path.move(to: p(1.8, 8))
    path.addArc(tangent1End: p(1.8, 3.2), tangent2End: p(6, 3.2), radius: r)  // 左上
    path.addLine(to: p(6, 3.2))
    path.addLine(to: p(7.6, 4.8))  // タブの切り欠き
    path.addArc(tangent1End: p(14.2, 4.8), tangent2End: p(14.2, 13), radius: r)  // 右上
    path.addArc(tangent1End: p(14.2, 13), tangent2End: p(1.8, 13), radius: r)  // 右下
    path.addArc(tangent1End: p(1.8, 13), tangent2End: p(1.8, 3.2), radius: r)  // 左下
    path.closeSubpath()
    return path
  }
}

/// 地球儀グリフ（GlobeGlyph・viewBox16・stroke 1.2）。円＋経線楕円＋赤道。
struct GlobeGlyph: View {
  var size: CGFloat = 12
  let color: Color

  var body: some View {
    GlobeGlyphShape()
      .stroke(color, style: StrokeStyle(lineWidth: 1.2 * size / 16))
      .frame(width: size, height: size)
  }
}

struct GlobeGlyphShape: Shape {
  func path(in rect: CGRect) -> Path {
    let k = rect.width / 16
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * k, y: rect.minY + y * k)
    }
    var path = Path()
    // 外円 r6.2
    path.addEllipse(
      in: CGRect(
        x: (8 - 6.2) * k + rect.minX, y: (8 - 6.2) * k + rect.minY,
        width: 6.2 * 2 * k, height: 6.2 * 2 * k))
    // 経線楕円 rx2.8 ry6.2
    path.addEllipse(
      in: CGRect(
        x: (8 - 2.8) * k + rect.minX, y: (8 - 6.2) * k + rect.minY,
        width: 2.8 * 2 * k, height: 6.2 * 2 * k))
    // 赤道
    path.move(to: p(1.8, 8))
    path.addLine(to: p(14.2, 8))
    return path
  }
}

#if DEBUG
  #Preview("ToolRail") {
    HStack(spacing: 20) {
      ForEach([EditorTool.tree, .git, .browser], id: \.self) { tool in
        ToolRailView(
          tool: tool, paneOpen: true, hasChanges: true, devServerRunning: true, onSelect: { _ in }
        )
        .frame(height: 140)
      }
    }
    .padding()
    .background(Color.theme.paneWash)
    .background(Color.theme.bgBase)
  }
#endif
