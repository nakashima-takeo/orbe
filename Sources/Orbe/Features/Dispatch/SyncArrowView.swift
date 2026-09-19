import SwiftUI

/// upstream との差を示す細い矢印（↑ / ↓）。**文字として置く**——寸法は並ぶ字のサイズ `em` から導き
/// （枠 0.46em × 0.74em・線幅 0.10em・丸キャップ丸結合）、色は前景色に従う。
/// `HStack(alignment: .firstTextBaseline)` に並べると、枠の下辺が字のベースラインに揃う。
struct SyncArrowView: View {
  enum Direction {
    case up, down
  }

  let direction: Direction
  /// 並ぶ字のサイズ。
  let em: CGFloat

  var body: some View {
    path
      .stroke(style: StrokeStyle(lineWidth: em * 0.1, lineCap: .round, lineJoin: .round))
      .frame(width: em * 0.46, height: em * 0.74)
  }

  /// viewBox 4.6 × 7.4 の 3 本の線（軸 1 本＋矢先 2 本）を `em` へスケールする。
  private var path: Path {
    var p = Path()
    switch direction {
    case .down:
      p.move(to: CGPoint(x: 2.3, y: 0.5))
      p.addLine(to: CGPoint(x: 2.3, y: 6.9))
      p.move(to: CGPoint(x: 0.5, y: 5.3))
      p.addLine(to: CGPoint(x: 2.3, y: 6.9))
      p.addLine(to: CGPoint(x: 4.1, y: 5.3))
    case .up:
      p.move(to: CGPoint(x: 2.3, y: 6.9))
      p.addLine(to: CGPoint(x: 2.3, y: 0.5))
      p.move(to: CGPoint(x: 0.5, y: 2.1))
      p.addLine(to: CGPoint(x: 2.3, y: 0.5))
      p.addLine(to: CGPoint(x: 4.1, y: 2.1))
    }
    return p.applying(CGAffineTransform(scaleX: em / 10, y: em / 10))
  }
}

/// 矢印と件数の組（`↓12`）。矢印の後ろに 0.3em を空ける。
struct SyncCountLabel: View {
  let direction: SyncArrowView.Direction
  let count: Int
  let em: CGFloat

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: em * 0.3) {
      SyncArrowView(direction: direction, em: em)
      Text("\(count)")
    }
  }
}

/// Local branch 行の同期ピル（`↑N` と `↓N` は別ピル・0 の側は立てない・順序 ↑ → ↓）。
/// 遅れは損失ではないので中立トーン（塗り `plainPillFill`・文字 muted）。
struct DispatchSyncPills: View {
  let sync: DispatchBranchSync

  var body: some View {
    HStack(spacing: Theme.Space.tick) {
      if sync.ahead > 0 { pill(.up, sync.ahead) }
      if sync.behind > 0 { pill(.down, sync.behind) }
    }
  }

  private func pill(_ direction: SyncArrowView.Direction, _ count: Int) -> some View {
    SyncCountLabel(direction: direction, count: count, em: Theme.Typography.sectionLabel.pointSize)
      .font(Font.theme.sectionLabel)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 7)
      .padding(.vertical, 1)
      .background(Capsule().fill(Color.theme.plainPillFill))
  }
}
