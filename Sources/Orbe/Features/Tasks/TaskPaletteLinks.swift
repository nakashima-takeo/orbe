import SwiftUI

/// 詳細のタイトルの上の、主の結び付き（「⊙ orbe#212」。owner は出さない）。
struct TaskPrimaryLinkHeading: View {
  let link: TaskLink

  var body: some View {
    HStack(spacing: Theme.Space.note) {
      TaskLinkGlyph(kind: link.kind)
      Text("\(link.item.repoName)#\(link.item.number)")
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.accentBright)
        .lineLimit(1)
    }
  }
}

/// 詳細の「Issue・PR」の欄。各行は ↑↓ で止まる場所で、クリックで開き、ホバーか選択で出る「外す」で外す。
/// タイトルと状態は置き場の答えから引き、値が無い・実体の種別が保存した種別と違えば番号だけを出す。
/// 末尾の「＋ 結び付ける」（結び付きが 0 件でも出る）は、↵ かクリックで GitHub タブの項目を選ぶ状態へ入る。
struct TaskPaletteLinks: View {
  @Bindable var model: TaskPaletteModel
  let task: TaskItem
  @Environment(\.localization) private var l10n
  @State private var hoveredLink: GitHubItemID?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(l10n.string(.taskPaletteFieldLinks))
        .font(Font.theme.sectionLabel)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.bottom, Theme.Space.tick)
      ForEach(task.links, id: \.item) { link in
        linkRow(link, primary: task.links.first?.item)
      }
      addRow
    }
    .padding(.horizontal, Theme.Space.beat)
    .padding(.vertical, Theme.Space.beat)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.md)
        .fill(Color.theme.surfaceInk.opacity(0.04))
    )
  }

  private func linkRow(_ link: TaskLink, primary: GitHubItemID?) -> some View {
    let focused = model.area == .detail(.link(link.item))
    let summary = GitHubItemText.summary(link, model.githubItems.answers)
    return HStack(spacing: Theme.Space.note) {
      TaskLinkGlyph(kind: link.kind)
      Text(GitHubItemText.label(link.item, primary: primary))
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize()
      if let summary {
        Text(summary.title)
          .font(Font.theme.taskText)
          .foregroundStyle(Color.theme.textPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: Theme.Space.step)
      if let summary { linkState(summary).font(Font.theme.codeCompact).fixedSize() }
      if focused || hoveredLink == link.item {
        Text("·").font(Font.theme.codeCompact).foregroundStyle(Color.theme.textMuted)
        Button {
          model.unlink(link.item)
        } label: {
          Text(l10n.string(.taskPaletteUnlink))
            .font(Font.theme.codeCompact)
            .foregroundStyle(Color.theme.textMuted)
        }
        .buttonStyle(.plain)
        .focusable(false)
      }
    }
    .frame(height: 30)
    .padding(.horizontal, Theme.Space.step)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(focused ? Color.theme.selectionFill : .clear)
    )
    .padding(.horizontal, -Theme.Space.step)
    .contentShape(Rectangle())
    .onTapGesture { model.openLink(link.item) }
    .onHover { hovering in
      if hovering {
        hoveredLink = link.item
      } else if hoveredLink == link.item {
        hoveredLink = nil
      }
    }
  }

  /// 「＋ 結び付ける」と、右に「ブランチの PR は自動」。
  private var addRow: some View {
    let focused = model.area == .detail(.addLink)
    return HStack(spacing: Theme.Space.note) {
      Text("＋ " + l10n.string(.taskPaletteAddLink))
        .font(Font.theme.taskText)
        .foregroundStyle(Color.theme.accentBright)
        .lineLimit(1)
        .fixedSize()
      Spacer(minLength: Theme.Space.step)
      Text(l10n.string(.taskPaletteBranchPRAuto))
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
    }
    .frame(height: 30)
    .padding(.horizontal, Theme.Space.step)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(focused ? Color.theme.selectionFill : .clear)
    )
    .padding(.horizontal, -Theme.Space.step)
    .contentShape(Rectangle())
    .onTapGesture { model.tapAddLink() }
  }

  /// 右の状態。Issue は open / closed、PR は「✓ CI · レビュー待ち」「マージ済み」「閉じた」など。
  private func linkState(_ summary: GitHubItemSummary) -> Text {
    let muted = { (text: String) in Text(text).foregroundStyle(Color.theme.textMuted) }
    switch GitHubItemText.state(summary) {
    case .issue(let open):
      return muted(GitHubItemText.issueStateText(open: open, l10n.language))
    case .pullRequest(let checks, let phase):
      var parts: [Text] = []
      if let checks { parts.append(TaskChecksMark.text(checks) + muted(" CI")) }
      if let phase { parts.append(muted(GitHubItemText.phaseText(phase, l10n.language))) }
      return parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + muted(" · ") + $1 }
    }
  }
}
