import SwiftUI

/// clean 行の語彙 1 つ。**色はトーンからの写像 1 本だけを通る**——語彙が増えても色の付け方が分岐せず、
/// 塗りのあるピルと塗らない素文字の別も語彙自身（`isPill`）が持つ。
/// **git / gh の語（`[gone]` / `locked` / `PR #N merged → <base>` / `merged → <実マージ先>` / `remote +N` /
/// `main worktree`）は L10n しない**——訳すと出力と対応が取れなくなる技術語。
struct DispatchCleanChip: View {
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
        n, one: .dispatchCleanUncommittedOne, other: .dispatchCleanUncommittedOther)
    case .untracked(let n):
      return l10n.plural(n, one: .dispatchCleanUntrackedOne, other: .dispatchCleanUntrackedOther)
    case .inProgress(let operation):
      return l10n.format(.dispatchCleanInProgress, operation.name)
    case .prunable: return l10n.string(.dispatchCleanPrunable)
    case .mergedPR(let number, let base): return "PR #\(number) merged → \(base)"
    case .mergedInto(let branch): return "merged → \(branch)"
    case .savedOnRemote: return l10n.string(.dispatchCleanSavedOnRemote)
    case .remoteSynced: return l10n.string(.dispatchCleanRemoteSynced)
    case .remoteAhead(let n): return "remote +\(n)"
    case .unpushed: return l10n.string(.dispatchCleanUnpushed)
    case .openPR(let number): return "PR #\(number) open"
    case .gone: return "[gone]"
    case .ownCommits(let n):
      return l10n.plural(n, one: .dispatchCleanOwnCommitsOne, other: .dispatchCleanOwnCommitsOther)
    case .unverified: return l10n.string(.dispatchCleanUnverified)
    case .agentWorking: return l10n.string(.dispatchCleanAgentWorking)
    case .agentWaiting: return l10n.string(.dispatchCleanAgentWaiting)
    case .paneOpen: return l10n.string(.dispatchCleanPaneOpen)
    case .locked: return "locked"
    case .mainWorktree: return "main worktree"
    }
  }
}
