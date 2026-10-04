import SwiftUI

/// タスクの呼び名。主の結び付きがあれば「#221」、無ければ「『タイトル』」。
enum WorktreePaletteTaskText {
  static func name(_ task: TaskItem, _ l10n: LocalizationStore) -> String {
    task.links.first.map { "#\($0.item.number)" }
      ?? l10n.format(.worktreePaletteTaskTitle, task.title)
  }
}

/// 入力欄の右の、文脈のタスクの札（「#221 <タイトル> ⌫」）。クリックで外す（⌫ と同じ）。
struct WorktreePaletteTaskBadge: View {
  let task: TaskItem
  let onRemove: () -> Void
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      if let primary = task.links.first {
        Text("#\(primary.item.number)").fixedSize()
      }
      fontResolver.text(task.title, base: Theme.Typography.code)
        .lineLimit(1)
        .truncationMode(.tail)
      Text("⌫").font(Font.theme.meta).foregroundStyle(Color.theme.textMuted).fixedSize()
    }
    .font(Font.theme.code)
    .foregroundStyle(Color.theme.accentBright)
    .padding(.horizontal, Theme.Space.beat)
    .frame(height: 26)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.theme.tintAccent))
    .contentShape(Rectangle())
    .onTapGesture(perform: onRemove)
  }
}

/// worktree の行の右の、その worktree のタスク（状態のアイコン・#番号・タイトル・作業中か入力待ちの印）。
struct WorktreePaletteRowTaskBadge: View {
  let task: WorktreePaletteRowTask
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      TaskStatusGlyph(glyph: TaskPaletteTaskRow.Glyph(task.task), size: 12)
      if let primary = task.task.links.first {
        Text("#\(primary.item.number)").foregroundStyle(Color.theme.textMuted).fixedSize()
      }
      TruncatingSlot(task.task.title) {
        fontResolver.text($0, base: Theme.Typography.meta)
          .foregroundStyle(Color.theme.textSecondary)
      }
      if let agent = task.agent {
        StatusGlyphView(kind: agent.state == .working ? .working : .waiting, size: 10)
      }
    }
    .font(Font.theme.meta)
  }
}
