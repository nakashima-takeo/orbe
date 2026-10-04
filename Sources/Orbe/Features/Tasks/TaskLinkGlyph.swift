import SwiftUI

/// Issue / PR の印。Issue は中心に点のある円（緑）、PR はマージの印（紫）。形で区別し、色は補強に留める。
struct TaskLinkGlyph: View {
  let kind: GitHubItemKind
  var size: CGFloat = 13

  var body: some View {
    switch kind {
    case .issue:
      Canvas { context, canvasSize in
        let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 1, dy: 1)
        context.stroke(Path(ellipseIn: rect), with: .color(Color.theme.success), lineWidth: 1.2)
        let dot = rect.insetBy(dx: rect.width * 0.36, dy: rect.height * 0.36)
        context.fill(Path(ellipseIn: dot), with: .color(Color.theme.success))
      }
      .frame(width: size, height: size)
    case .pr:
      Canvas { context, canvasSize in
        let w = canvasSize.width
        let h = canvasSize.height
        let r = w * 0.13
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: x * w, y: y * h) }
        let ring = { (center: CGPoint) in
          Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        var lines = Path()
        lines.move(to: point(0.27, 0.15 + r / h))
        lines.addLine(to: point(0.27, 0.85 - r / h))
        lines.move(to: point(0.73, 0.85 - r / h))
        lines.addLine(to: point(0.73, 0.4))
        lines.addQuadCurve(to: point(0.5, 0.18), control: point(0.73, 0.18))
        lines.move(to: point(0.62, 0.06))
        lines.addLine(to: point(0.5, 0.18))
        lines.addLine(to: point(0.62, 0.3))
        let style = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        let color = GraphicsContext.Shading.color(Color.theme.accentBright)
        context.stroke(lines, with: color, style: style)
        for center in [point(0.27, 0.15), point(0.27, 0.85), point(0.73, 0.85)] {
          context.stroke(ring(center), with: color, style: style)
        }
      }
      .frame(width: size, height: size)
    }
  }
}

/// PR の状態の語と CI の印（一覧の PR の札と、詳細の Issue・PR の欄が共に使う）。
enum TaskPullRequestText {
  static func phase(_ phase: GitHubItemSummary.PullRequestPhase, _ l10n: LocalizationStore)
    -> String
  {
    switch phase {
    case .merged: l10n.string(.taskPalettePRMerged)
    case .closed: l10n.string(.taskPalettePRClosed)
    case .draft: l10n.string(.taskPalettePRDraft)
    case .reviewRequired: l10n.string(.taskPalettePRReviewRequired)
    case .approved: l10n.string(.taskPalettePRApproved)
    case .changesRequested: l10n.string(.taskPalettePRChangesRequested)
    }
  }

  static func checksMark(_ checks: GitHubItemSummary.Checks) -> Text {
    switch checks {
    case .success: Text("✓").foregroundStyle(Color.theme.success)
    case .failure: Text("✗").foregroundStyle(Color.theme.danger)
    case .pending: Text("⋯").foregroundStyle(Color.theme.textMuted)
    }
  }
}
