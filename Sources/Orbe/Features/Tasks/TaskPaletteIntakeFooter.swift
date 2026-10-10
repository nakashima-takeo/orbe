import SwiftUI

/// 受信タブのフッターの左（居場所と選択で、↵ が何をするか。失敗は赤で置き換える）。
struct TaskPaletteIntakeAction: View {
  @Bindable var model: TaskPaletteIntakeModel
  @Environment(\.localization) private var l10n

  var body: some View {
    if let error = model.error {
      Text(
        l10n.string(error == .accept ? .taskPaletteIntakeErrAccept : .taskPaletteIntakeErrRunning)
      )
      .foregroundStyle(Color.theme.danger)
    } else {
      switch model.place {
      case .proposals:
        if let proposal = model.selectedProposal {
          PaletteActionLine(
            key: "↵", template: l10n.string(.taskPaletteIntakeActionAccept),
            slots: [.emphasis(proposal.title)])
        }
      case .shelf:
        PaletteActionLine(
          key: "→", template: l10n.string(.taskPaletteIntakeActionProposals), slots: [])
      case .contents:
        if let intake = model.selectedIntake {
          PaletteActionLine(
            key: "↵", template: l10n.string(.taskPaletteIntakeActionRunNow),
            slots: [.emphasis(intake.definition.name)])
        }
      }
    }
  }
}

/// 受信タブのフッターの右のヒント。
struct TaskPaletteIntakeHints: View {
  @Bindable var model: TaskPaletteIntakeModel
  @Environment(\.localization) private var l10n

  var body: some View {
    switch model.place {
    case .proposals:
      if model.selectedProposal != nil {
        PaletteKeyHint(key: "⌘⌫", label: l10n.string(.taskPaletteIntakeDismiss))
        PaletteKeyHint(key: "⌘↵", label: l10n.string(.taskPaletteHintOpenInBrowser))
      }
      if model.selectedIntake != nil {
        PaletteKeyHint(key: "→", label: l10n.string(.taskPaletteIntakeContents))
      }
      PaletteKeyHint(key: "←", label: l10n.string(.taskPaletteIntakeHintShelf))
      PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteHintClose))
    case .shelf:
      PaletteKeyHint(key: "↑↓", label: l10n.string(.taskPaletteIntakeHintPick))
      PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteIntakeHintBack))
    case .contents:
      if let intake = model.selectedIntake {
        PaletteKeyHint(
          key: "space",
          label: l10n.string(intake.paused ? .taskPaletteIntakeResume : .taskPaletteIntakePause))
      }
      PaletteKeyHint(key: "⌘⌫", label: l10n.string(.taskPaletteDelete))
      PaletteKeyHint(key: "esc", label: l10n.string(.taskPaletteIntakeHintBack))
    }
  }
}
