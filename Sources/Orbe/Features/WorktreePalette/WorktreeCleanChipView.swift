import SwiftUI

/// clean 行の語彙 1 つ。**色はトーンからの写像 1 本だけを通る**——語彙が増えても色の付け方が分岐せず、
/// 塗りのあるピルと塗らない素文字の別も語彙自身（`isPill`）が持つ。
/// **git / gh の語（`[gone]` / `locked` / `PR #N merged → <base>` / `merged → <実マージ先>` / `remote +N` /
/// `main worktree`）は L10n しない**——訳すと出力と対応が取れなくなる技術語。
struct WorktreeCleanChip: View {
  let chip: CleanChip
  @Environment(\.localization) private var l10n

  var body: some View {
    if chip.isPill {
      Text(Self.text(chip, l10n))
        .font(Font.theme.sectionLabel)
        .foregroundStyle(chip.tone.foreground)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .background(Capsule().fill(chip.tone.fill))
    } else {
      Text(Self.text(chip, l10n))
        .font(Font.theme.sectionLabel)
        .foregroundStyle(chip.tone.foreground)
        .lineLimit(1)
    }
  }

  static func text(_ chip: CleanChip, _ l10n: LocalizationStore) -> String {
    switch chip {
    case .uncommitted(let n):
      return l10n.plural(
        n, one: .worktreeCleanUncommittedOne, other: .worktreeCleanUncommittedOther)
    case .untracked(let n):
      return l10n.plural(n, one: .worktreeCleanUntrackedOne, other: .worktreeCleanUntrackedOther)
    case .inProgress(let operation):
      return l10n.format(.worktreeCleanInProgress, operation.name)
    case .prunable: return l10n.string(.worktreeCleanPrunable)
    case .mergedPR(let number, let base): return "PR #\(number) merged → \(base)"
    case .mergedInto(let branch): return "merged → \(branch)"
    case .onRemote: return l10n.string(.worktreeCleanOnRemote)
    case .remoteAhead(let n): return "remote +\(n)"
    case .unpushed: return l10n.string(.worktreeCleanUnpushed)
    case .openPR(let number): return "PR #\(number) open"
    case .gone: return "[gone]"
    case .ownCommits(let n):
      return l10n.plural(n, one: .worktreeCleanOwnCommitsOne, other: .worktreeCleanOwnCommitsOther)
    case .unverified: return l10n.string(.worktreeCleanUnverified)
    case .agentWorking: return l10n.string(.worktreeCleanAgentWorking)
    case .agentWaiting: return l10n.string(.worktreeCleanAgentWaiting)
    case .tabOpen: return l10n.string(.worktreeCleanTabOpen)
    case .locked: return "locked"
    case .mainWorktree: return "main worktree"
    }
  }
}
