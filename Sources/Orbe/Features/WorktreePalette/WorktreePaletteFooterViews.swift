import SwiftUI

// worktree パレットのフッターの部品。一覧モードと最新化モードが共有する。

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

/// フッターの実行説明。`↵ <target> <前置> <agent> を新しいタブで起動` の骨を 1 つの Text に連結して
/// 単位で truncate する（狭幅で個々に折り返して崩れるのを防ぐ）。
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

/// フッターの ↵ の説明。言語ごとの語順をテンプレート（`%1$@`…の位置指定）が持ち、差し込む値だけを
/// 色分けして 1 つの Text に連結する（単位で truncate し、狭幅で個々に折り返して崩れない）。
/// 地の語は muted、名前とベースは textPrimary、起動先は accent。
struct WorktreePaletteEnterLine: View {
  enum Slot {
    case name(String)
    case agent(String)

    var text: String {
      switch self {
      case .name(let text), .agent(let text): text
      }
    }
  }

  let template: String
  let slots: [Slot]
  /// 先頭に `↵ ` を置くか（ベースのバーの「なし — …」は置かない）。
  var leadsWithReturn = true
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    Self.segments(template, count: slots.count).reduce(
      Text(leadsWithReturn ? "↵ " : "").foregroundStyle(Color.theme.textMuted)
    ) { line, segment in
      switch segment {
      case .literal(let text):
        line + Text(text).foregroundStyle(Color.theme.textMuted)
      case .slot(let index):
        line + text(for: slots[index])
      }
    }
    .font(Font.theme.meta)
    .lineLimit(1)
    .truncationMode(.tail)
  }

  private func text(for slot: Slot) -> Text {
    switch slot {
    case .name(let name):
      fontResolver.text(name, base: Theme.Typography.meta).foregroundStyle(Color.theme.textPrimary)
    case .agent(let agent):
      Text(agent).foregroundStyle(Color.theme.accentPrimary)
    }
  }

  enum Segment: Equatable {
    case literal(String)
    case slot(Int)
  }

  /// `%N$@` を差し込み位置（0 始まり）に、それ以外を地の語に分ける。範囲外の位置は地の語のまま残す。
  static func segments(_ template: String, count: Int) -> [Segment] {
    var segments: [Segment] = []
    var rest = Substring(template)
    while let match = rest.firstMatch(of: #/%(\d)\$@/#) {
      let index = Int(match.output.1)! - 1
      let before = String(rest[..<match.range.lowerBound])
      if !before.isEmpty { segments.append(.literal(before)) }
      segments.append(
        (0..<count).contains(index) ? .slot(index) : .literal(String(rest[match.range])))
      rest = rest[match.range.upperBound...]
    }
    if !rest.isEmpty { segments.append(.literal(String(rest))) }
    return segments
  }
}

/// フッター右端のキーヒント 1 つ（キーは textPrimary・ラベルは親の色）。
struct WorktreePaletteKeyHint: View {
  let key: String
  let label: String

  var body: some View {
    HStack(spacing: Theme.Space.tick) {
      Text(key).foregroundStyle(Color.theme.textPrimary)
      Text(label)
    }
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
    let agent = WorktreePaletteEnterLine.Slot.agent(model.selectedTargetName)
    switch enter {
    case .openWorktree(let target), .openDirectory(let target):
      WorktreePaletteEnterLine(
        template: l10n.string(.worktreePaletteEnterOpen), slots: [.name(target), agent])
    case .checkout(let target), .trackRemote(let target, _):
      WorktreePaletteEnterLine(
        template: l10n.string(.worktreePaletteEnterCheckout), slots: [.name(target), agent])
    case .create(let target):
      if let base = model.selectedBaseChoice, base.base != nil {
        WorktreePaletteEnterLine(
          template: l10n.string(.worktreePaletteEnterCreate),
          slots: [.name(target), agent, .name(base.name)])
      } else {
        WorktreePaletteEnterLine(template: l10n.string(.worktreePaletteEnterPickBase), slots: [])
      }
    case .clean:
      WorktreePaletteEnterLine(template: l10n.string(.worktreePaletteEnterClean), slots: [])
    }
  }

  /// 「↑↓ 選択」は選べる行が 2 つ以上あるときだけ出す。
  private var keyHints: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      if model.items.count >= 2 {
        WorktreePaletteKeyHint(key: "↑↓", label: l10n.string(.worktreePaletteHintSelect))
      }
      WorktreePaletteKeyHint(key: "esc", label: l10n.string(.worktreePaletteHintClose))
    }
    .font(Font.theme.sectionLabel)
    .foregroundStyle(Color.theme.textMuted)
    .fixedSize()
  }
}
