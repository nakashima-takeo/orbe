import SwiftUI

/// タスクの状態のアイコン（未着手・進行中・待ち・完了）。形で区別し、色は補強に留める
/// （未着手＝空の円、進行中＝◐ のブランドグリフ、待ち＝破線の円と時計の針、完了＝塗りの円に ✓）。
struct TaskStatusGlyph: View {
  let glyph: TaskPaletteTaskRow.Glyph
  var size: CGFloat = 14

  var body: some View {
    if glyph == .inProgress {
      OrbeMarkShape()
        .fill(Color.theme.glyphGradient, style: FillStyle(eoFill: true))
        .frame(width: size, height: size)
    } else {
      outline
    }
  }

  private var outline: some View {
    Canvas { context, canvasSize in
      let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 1, dy: 1)
      let ring = Path(ellipseIn: rect)
      switch glyph {
      case .todo:
        context.stroke(ring, with: .color(Color.theme.textMuted), lineWidth: 1.2)
      case .waiting:
        context.stroke(
          ring, with: .color(Color.theme.textMuted),
          style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1.6, 2.2]))
        var hands = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        hands.move(to: CGPoint(x: center.x, y: center.y - rect.height * 0.26))
        hands.addLine(to: center)
        hands.addLine(to: CGPoint(x: center.x + rect.width * 0.2, y: center.y + rect.height * 0.12))
        context.stroke(
          hands, with: .color(Color.theme.textMuted),
          style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
      case .done:
        context.fill(ring, with: .color(Color.theme.textMuted.opacity(0.7)))
        var check = Path()
        check.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.midY + rect.height * 0.02))
        check.addLine(
          to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.midY + rect.height * 0.18))
        check.addLine(
          to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.midY - rect.height * 0.14))
        context.stroke(
          check, with: .color(Color.theme.checkStroke),
          style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
      case .inProgress:
        break
      }
    }
    .frame(width: size, height: size)
  }
}
