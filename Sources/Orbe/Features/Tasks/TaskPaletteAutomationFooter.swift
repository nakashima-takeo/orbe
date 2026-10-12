import SwiftUI

/// 受信タブのフッターの左（居場所と選択で、↵ が何をするか。失敗は赤で置き換える）。
struct TaskPaletteAutomationAction: View {
  @Bindable var model: TaskPaletteAutomationModel
  @Environment(\.localization) private var l10n

  var body: some View {
    if let error = model.error {
      Text(l10n.string(error.message))
        .foregroundStyle(Color.theme.danger)
    } else {
      switch model.place {
      case .proposals:
        if let proposal = model.selectedProposal {
          PaletteActionLine(
            key: "↵", template: l10n.string(.taskPaletteAutomationActionAccept),
            slots: [.emphasis(proposal.title)])
        }
      case .shelf:
        PaletteActionLine(
          key: "→", template: l10n.string(.taskPaletteAutomationActionProposals), slots: [])
      case .contents:
        if let automation = model.selectedAutomation {
          PaletteActionLine(
            key: AutomationHand.Operation.runNow.key,
            template: l10n.string(.taskPaletteAutomationActionRunNow),
            slots: [.emphasis(automation.definition.name)])
        }
      }
    }
  }
}

/// 受信タブのフッターの右のヒント。
struct TaskPaletteAutomationHints: View {
  @Bindable var model: TaskPaletteAutomationModel
  @Environment(\.localization) private var l10n

  var body: some View {
    switch model.place {
    case .proposals:
      if model.selectedProposal != nil {
        PaletteKeyHint(key: "⌘⌫", label: l10n.string(.taskPaletteAutomationDismiss))
        PaletteKeyHint(key: "⌘↵", label: l10n.string(.taskPaletteHintOpenInBrowser))
      }
      if model.selectedAutomation != nil {
        PaletteKeyHint(key: "→", label: l10n.string(.taskPaletteAutomationContents))
      }
      PaletteKeyHint(key: "←", label: l10n.string(.taskPaletteAutomationHintShelf))
      PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintClose))
    case .shelf:
      PaletteKeyHint(key: "↑↓", label: l10n.string(.taskPaletteAutomationHintPick))
      PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteAutomationHintBack))
    case .contents:
      if let automation = model.selectedAutomation {
        ForEach([AutomationHand.Operation.togglePause, .delete], id: \.self) { operation in
          PaletteKeyHint(
            key: operation.key, label: l10n.string(operation.title(paused: automation.paused)))
        }
      }
      PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteAutomationHintBack))
    }
  }
}
