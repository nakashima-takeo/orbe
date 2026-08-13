import SwiftUI

/// 試聴中インジケータ（3 本バー）。「今この行が鳴っている」だけを示す（波形の再現ではない）。
/// 位相は `StatusGlyphView.stateMotion` と同じく `TimelineView(.animation)` の `context.date` から
/// 都度算出する——`withAnimation(.repeatForever)` は body 再評価（↑↓ のたびに起きる）で凍るため。
struct EqBarsView: View {
  /// バーの色。試聴対象の状態色（`AgentSoundEvent.glyphKind.stateColor`）を呼び出し側が解決して渡す。
  let color: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 見本の実寸（幅 2 / 高さ 3⇄10 / gap 2）。`Theme` の格子に無いのでコンポーネント局所の定数
  /// （`PaletteCard.capHeight` と同流儀。グローバルトークンは足さない）。
  private let barWidth: CGFloat = 2
  private let gap: CGFloat = 2
  private let low: CGFloat = 3
  private let high: CGFloat = 10
  private let delays: [Double] = [0, Theme.Motion.eqStagger, Theme.Motion.eqStagger * 2]

  var body: some View {
    if reduceMotion {
      // 静止。位相差のおかげで 3 本が別々の高さで止まり、EQ の形のまま読める（別形状を発明しない）。
      bars(at: Theme.Motion.eq / 4)
    } else {
      TimelineView(.animation) { context in
        bars(at: context.date.timeIntervalSinceReferenceDate)
      }
    }
  }

  private func bars(at t: Double) -> some View {
    HStack(alignment: .bottom, spacing: gap) {
      ForEach(delays, id: \.self) { delay in
        Rectangle().fill(color).frame(width: barWidth, height: height(t, delay))
      }
    }
    .frame(height: high, alignment: .bottom)
  }

  /// 見本 `@keyframes eqbar { 0%,100% { height: 3px } 50% { height: 10px } }` の cos 往復近似
  /// （`waiting` の float と同じ正弦イージング）。
  private func height(_ t: Double, _ delay: Double) -> CGFloat {
    var cycle = ((t - delay) / Theme.Motion.eq).truncatingRemainder(dividingBy: 1)
    if cycle < 0 { cycle += 1 }
    let phase = (1 - cos(cycle * 2 * .pi)) / 2
    return low + (high - low) * CGFloat(phase)
  }
}

#Preview("EqBarsView") {
  HStack(spacing: Theme.Space.span) {
    EqBarsView(color: Color.theme.stateDone)
    EqBarsView(color: Color.theme.stateWaiting)
  }
  .padding(Theme.Space.phrase)
  .background(Color.theme.bgSunken)
}
