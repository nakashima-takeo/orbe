import SwiftUI

/// ツール共通のヘッダー枠（HeaderRow・高さ 32・下罫線）。
/// ツール別ヘッダー（TreeHeader / GitHeader / BrowserHeader）がこの枠に中身を差す。
struct HeaderRow<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 8) { content }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .overlay(alignment: .bottom) {
        Rectangle().fill(Color.theme.surfaceInk.opacity(0.07)).frame(height: 1)
      }
  }
}

/// ツリーツールのヘッダー（TreeHeader）。閲覧に徹するのでファイル検索のみ（描画のみ・無配線）。
struct TreeHeader: View {
  @Environment(\.localization) private var l10n

  var body: some View {
    HeaderRow {
      HStack(spacing: 6) {
        Text(l10n.string(.editorSearchFiles))
          .font(Font.theme.paneControl)
        Spacer(minLength: 0)
        Text(verbatim: "⌘P")
          .font(Font.theme.paneFootnote)
      }
      .foregroundStyle(Color.theme.textMuted)
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .frame(maxWidth: .infinity)
      .background(RoundedRectangle(cornerRadius: 4).fill(Color.theme.tabRowBg))
    }
  }
}

/// git ツールのヘッダー（GitHeader）。branch・追跡（↑N ↓M）・変更量（+A −D）を集約する
/// （旧ステータスバー＋レール脇情報の受け皿）。branch `▾` は描画のみ・無配線。
struct GitHeader: View {
  @Bindable var model: EditorPaneModel

  var body: some View {
    let stat = model.totalStat
    return HeaderRow {
      branchChip
      if model.upstream != nil {
        Text(verbatim: "↑\(model.ahead ?? 0) ↓\(model.behind ?? 0)")
          .font(Font.theme.paneAnnotation)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
      }
      if stat.add > 0 || stat.del > 0 {
        AddDelText(add: stat.add, del: stat.del)
          .font(Font.theme.paneAnnotation)
      }
      Spacer(minLength: 0)
    }
  }

  private var branchChip: some View {
    HStack(spacing: 5) {
      BranchGlyph(size: 9, color: Color.theme.accentPrimary)
      Text(model.branch)
        .lineLimit(1)
        .truncationMode(.tail)
      Text(verbatim: "▾").opacity(0.6)
    }
    .font(Font.theme.paneRow)
    .foregroundStyle(Color.theme.accentPrimary)
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(RoundedRectangle(cornerRadius: 4).fill(Color.theme.tintAccent))
  }
}

/// git ブランチグリフ（GitHub octicon `git-branch-16` を座標移植）。
/// GitHeader と ToolRail の双方が使う。viewBox 0..16。輪 3 つ＋幹 2 本＋肘チューブ＋矢頭を
/// nonzero で合成し、内穴は逆回りで抜く。
struct BranchGlyph: View {
  var size: CGFloat = 10
  let color: Color

  var body: some View {
    BranchGlyphShape()
      .fill(color, style: FillStyle(eoFill: false))
      .frame(width: size, height: size)
  }
}

struct BranchGlyphShape: Shape {
  func path(in rect: CGRect) -> Path {
    let k = rect.width / 16
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * k, y: rect.minY + y * k)
    }
    var path = Path()

    // 外形（すべて同回り）: 輪の外周 3 つ
    for center in [p(3.75, 3.25), p(3.75, 12.75), p(12.75, 12.75)] {
      path.addArc(
        center: center, radius: 2.25 * k, startAngle: .degrees(0), endAngle: .degrees(360),
        clockwise: false)
      path.closeSubpath()
    }
    // 幹（左: 輪中心間・右: 肘の着地 y=5 から下輪中心まで）
    path.addRect(CGRect(x: p(3, 3.25).x, y: p(3, 3.25).y, width: 1.5 * k, height: 9.5 * k))
    path.addRect(CGRect(x: p(12, 5).x, y: p(12, 5).y, width: 1.5 * k, height: 7.75 * k))
    // 肘チューブ（(10,2.5)→(11,2.5)→外弧 r2.5→(13.5,5)、内側 (12,5)→内弧 r1→(11,4)→(10,4)）
    path.move(to: p(10, 2.5))
    path.addLine(to: p(11, 2.5))
    path.addArc(
      center: p(11, 5), radius: 2.5 * k, startAngle: .degrees(-90), endAngle: .degrees(0),
      clockwise: false)
    path.addLine(to: p(12, 5))
    path.addArc(
      center: p(11, 5), radius: 1 * k, startAngle: .degrees(0), endAngle: .degrees(-90),
      clockwise: true)
    path.addLine(to: p(10, 4))
    path.closeSubpath()
    // 矢頭（右辺 x=10・先端 (7.18, 3.25)。octicon の r0.25 の角丸はこの寸法では実質不可視のため直線）
    path.move(to: p(10, 0.85))
    path.addLine(to: p(10, 5.65))
    path.addLine(to: p(7.18, 3.25))
    path.closeSubpath()
    // 内穴（逆回り）
    for center in [p(3.75, 3.25), p(3.75, 12.75), p(12.75, 12.75)] {
      path.addArc(
        center: center, radius: 0.75 * k, startAngle: .degrees(0), endAngle: .degrees(-360),
        clockwise: true)
      path.closeSubpath()
    }
    return path
  }
}

#if DEBUG
  #Preview("EditorPane Headers") {
    let model = EditorPaneModel()
    model.branch = "feature/agent-hooks"
    model.upstream = "origin/main"
    model.ahead = 3
    model.behind = 0
    return VStack(spacing: Theme.Space.bar) {
      TreeHeader()
      GitHeader(model: model)
      HStack(spacing: Theme.Space.bar) {
        BranchGlyph(size: 9, color: Color.theme.accentPrimary)
        BranchGlyph(size: 16, color: Color.theme.textSecondary)
        BranchGlyph(size: 48, color: Color.theme.textPrimary)
      }
    }
    .padding()
    .frame(width: 380)
    .background(Color.theme.bgBase)
  }
#endif
