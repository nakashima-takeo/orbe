import SwiftUI

// worktree パレットのフッターの部品。busy 表示は一覧と最新化が共有し、↵ の説明は一覧
// （`PaletteActionLine`）と最新化（`LaunchLine`）で描き方が分かれる。

/// フッターの busy 表示（作成中・最新化中・リモートのブランチの確かめ待ち）。左端の `↵` を出さず、gh「読み込み中…」行と同語彙の
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

/// 一覧のフッター。選択行の ↵ が何をするかを言い（タスクから開いたときは、タスクに起こすことを続けて
/// 言う）、右にキーヒント。作成中と、預かった作成がリモートのブランチを待つ間は busy 表示、失敗は赤。
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
    } else if model.isAwaitingRemoteBranches {
      WorktreePaletteBusyLabel(text: l10n.string(.worktreePaletteCheckingRemote))
    } else if let error = model.errorMessage {
      Text(error).foregroundStyle(Color.theme.danger)
    } else if let enter = model.selectedItem?.enter {
      let line = line(enter)
      let effect = effect(model.taskEffect, after: line.slots.count)
      PaletteActionLine(
        key: "↵", template: line.template + effect.template, slots: line.slots + effect.slots)
    }
  }

  private func line(_ enter: WorktreePaletteEnter) -> (
    template: String, slots: [PaletteActionLine.Slot]
  ) {
    let agent = PaletteActionLine.Slot.accent(model.selectedTargetName)
    switch enter {
    case .openWorktree(let target), .openDirectory(let target):
      return (l10n.string(.worktreePaletteEnterOpen), [.emphasis(target), agent])
    case .checkout(let target), .trackRemote(let target, _):
      return (l10n.string(.worktreePaletteEnterCheckout), [.emphasis(target), agent])
    case .create(let target):
      if let base = model.selectedBaseChoice, base.base != nil {
        return (
          l10n.string(.worktreePaletteEnterCreate),
          [.emphasis(target), agent, .emphasis(base.name)]
        )
      }
      return (l10n.string(.worktreePaletteEnterPickBase), [])
    case .clean:
      return (l10n.string(.worktreePaletteEnterClean), [])
    }
  }

  /// ↵ がタスクに起こすこと（「 · #221 を進行中に」「 · #212 から #221 へ付け替え」）。差し込み位置は
  /// ↵ の説明の後ろへずらす。
  private func effect(_ effect: WorktreePaletteTaskEffect?, after offset: Int) -> (
    template: String, slots: [PaletteActionLine.Slot]
  ) {
    guard let effect else { return ("", []) }
    let name = { (task: TaskItem) in WorktreePaletteTaskText.name(task, l10n) }
    let key: L10nKey
    var slots: [PaletteActionLine.Slot] = [.emphasis(name(effect.task))]
    switch (effect.begins, effect.previousOwner) {
    case (true, nil): key = .worktreePaletteEffectBegin
    case (true, let previous?):
      key = .worktreePaletteEffectBeginReassign
      slots.append(.emphasis(name(previous)))
    case (false, let previous?):
      key = .worktreePaletteEffectReassign
      slots.append(.emphasis(name(previous)))
    case (false, nil): return ("", [])
    }
    let template = l10n.string(key).replacing(#/%(\d)\$@/#) { match in
      "%\(Int(match.output.1)! + offset)$@"
    }
    return (template, slots)
  }

  /// タスクから開いていて入力が空の間は「⌫ 外す」、そうでなければ選べる行が 2 つ以上あるときだけ「↑↓ 選択」。
  private var keyHints: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      if model.task != nil, model.query.isEmpty {
        PaletteKeyHint(key: "⌫", label: l10n.string(.worktreePaletteHintRemoveTask))
      } else if model.items.count >= 2 {
        PaletteKeyHint(key: "↑↓", label: l10n.string(.worktreePaletteHintSelect))
      }
      PaletteKeyHint(key: "esc", label: l10n.string(.worktreePaletteHintClose))
    }
    .font(Font.theme.sectionLabel)
    .foregroundStyle(Color.theme.textMuted)
    .fixedSize()
  }
}
