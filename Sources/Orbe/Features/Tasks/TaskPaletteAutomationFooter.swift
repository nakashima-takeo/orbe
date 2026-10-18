import SwiftUI

/// 提案タブのフッターの左（居場所と選択で、主なキーが何をするか。失敗は赤で置き換える）。
struct TaskPaletteAutomationAction: View {
  @Bindable var model: TaskPaletteAutomationModel
  @Environment(\.localization) private var l10n

  var body: some View {
    if let error = model.error {
      Text(l10n.string(error.message))
        .foregroundStyle(Color.theme.danger)
    } else {
      switch model.place {
      case .field:
        EmptyView()
      case .shelf:
        if let automation = model.selectedAutomation {
          PaletteActionLine(
            key: "⌘↵", template: l10n.string(.taskPaletteAutomationActionRefresh),
            slots: [.emphasis(automation.name)])
        } else {
          PaletteActionLine(
            key: "→", template: l10n.string(.taskPaletteAutomationActionProposals), slots: [])
        }
      case .proposals:
        if let proposal = model.selectedProposal {
          PaletteActionLine(
            key: "↵", template: l10n.string(.taskPaletteAutomationActionAccept),
            slots: [.emphasis(proposal.title)])
        }
      }
    }
  }
}

/// 提案タブのフッターの右のヒント。
struct TaskPaletteAutomationHints: View {
  @Bindable var model: TaskPaletteAutomationModel
  let cyclesTabs: Bool
  @Environment(\.localization) private var l10n

  var body: some View {
    switch model.place {
    case .field:
      TaskPaletteHintRow(cyclesTabs: cyclesTabs, escape: .taskPaletteHintClose) {
        PaletteKeyHint(key: "↓", label: l10n.string(.taskPaletteAutomationHintShelf))
      }
    case .shelf:
      TaskPaletteHintRow(cyclesTabs: cyclesTabs, escape: .taskPaletteAutomationHintBack) {
        PaletteKeyHint(key: "↑↓", label: l10n.string(.taskPaletteAutomationHintPick))
        PaletteKeyHint(key: "→", label: l10n.string(.taskPaletteAutomationHintProposals))
      }
    case .proposals:
      TaskPaletteHintRow(cyclesTabs: cyclesTabs, escape: .taskPaletteAutomationHintBack) {
        if model.selectedProposal != nil {
          PaletteKeyHint(key: "⌘↵", label: l10n.string(.taskPaletteMakeTaskOpen))
          PaletteKeyHint(key: "⌘⌫", label: l10n.string(.taskPaletteAutomationDismiss))
          PaletteKeyHint(key: "⌘O", label: l10n.string(.taskPaletteHintOpenInBrowser))
        }
        PaletteKeyHint(key: "←", label: l10n.string(.taskPaletteAutomationHintShelf))
      }
    }
  }
}
