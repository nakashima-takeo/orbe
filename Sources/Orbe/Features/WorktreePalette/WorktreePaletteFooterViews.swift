import SwiftUI

// worktree パレットのフッターの部品。busy 表示は一覧と最新化が共有し、↵ の説明は一覧
// （`PaletteActionLine`）と最新化（`LaunchLine`）で描き方が分かれる。

/// フッターの busy 表示（作成中・最新化中）。左端の `↵` を出さず、gh「読み込み中…」行と同語彙の
/// working スピナ＋muted ラベルのみ。
struct WorktreePaletteBusyLabel: View {
  let text: String

  var body: some View {
    HStack(spacing: Theme.Space.note) {
      StatusGlyphView(kind: .working, size: 10)
      Text(text).foregroundStyle(Color.theme.textMuted)
    }
    .font(Font.theme.meta)
  }
}

/// 最新化画面のフッターの実行説明。`↵ <target> <前置> <agent> を新しいタブで起動` の骨を 1 つの Text に
/// 連結して単位で truncate する（狭幅で個々に折り返して崩れるのを防ぐ）。
struct WorktreePaletteLaunchLine: View {
  let target: String
  let preposition: L10nKey
  let agent: String
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    (Text("↵ ").foregroundStyle(Color.theme.textMuted)
      + fontResolver.text(target, base: Theme.Typography.meta)
      .foregroundStyle(Color.theme.textPrimary)
      + Text(" " + l10n.string(preposition) + " ").foregroundStyle(Color.theme.textMuted)
      + Text(agent).foregroundStyle(Color.theme.accentPrimary)
      + Text(" " + l10n.string(.worktreePaletteLaunchSuffix)).foregroundStyle(Color.theme.textMuted))
      .font(Font.theme.meta)
      .lineLimit(1)
      .truncationMode(.tail)
  }
}

/// 一覧のフッター。選択行の ↵ が何をするかを言い、右にキーヒント。作成中は busy 表示、失敗は赤。
struct WorktreePaletteListFooter: View {
  @Bindable var model: WorktreePaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      description
        .font(Font.theme.meta)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Space.step)
      // 入力ロック中は操作が無効なのでキーヒントも出さない（効かない案内を残さない＝UI が嘘をつかない）。
      if !model.isLocked {
        keyHints
          .layoutPriority(1)  // 狭幅ではキーヒントを残し説明側を truncate
      }
    }
  }

  @ViewBuilder private var description: some View {
    if model.isPreparing {
      WorktreePaletteBusyLabel(text: l10n.string(.worktreePalettePreparing))
    } else if let error = model.errorMessage {
      Text(error).foregroundStyle(Color.theme.danger)
    } else if let enter = model.selectedItem?.enter {
      line(enter)
    }
  }

  @ViewBuilder private func line(_ enter: WorktreePaletteEnter) -> some View {
    let agent = PaletteActionLine.Slot.accent(model.selectedTargetName)
    switch enter {
    case .openWorktree(let target), .openDirectory(let target):
      PaletteActionLine(
        key: "↵", template: l10n.string(.worktreePaletteEnterOpen),
        slots: [.emphasis(target), agent])
    case .checkout(let target), .trackRemote(let target, _):
      PaletteActionLine(
        key: "↵", template: l10n.string(.worktreePaletteEnterCheckout),
        slots: [.emphasis(target), agent])
    case .create(let target):
      if let base = model.selectedBaseChoice, base.base != nil {
        PaletteActionLine(
          key: "↵", template: l10n.string(.worktreePaletteEnterCreate),
          slots: [.emphasis(target), agent, .emphasis(base.name)])
      } else {
        PaletteActionLine(
          key: "↵", template: l10n.string(.worktreePaletteEnterPickBase), slots: [])
      }
    case .clean:
      PaletteActionLine(key: "↵", template: l10n.string(.worktreePaletteEnterClean), slots: [])
    }
  }

  /// 「↑↓ 選択」は選べる行が 2 つ以上あるときだけ出す。
  private var keyHints: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      if model.items.count >= 2 {
        PaletteKeyHint(key: "↑↓", label: l10n.string(.worktreePaletteHintSelect))
      }
      PaletteKeyHint(key: "esc", label: l10n.string(.worktreePaletteHintClose))
    }
    .font(Font.theme.sectionLabel)
    .foregroundStyle(Color.theme.textMuted)
    .fixedSize()
  }
}
