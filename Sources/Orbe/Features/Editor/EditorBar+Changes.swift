import SwiftUI

/// Changes の画面の、上のバーの部品。部品ごとに寄せる側と譲る順を名乗る（→ `editorBarPart`）。どれも git 管理下と分かっている
/// 間だけ出す。
extension EditorBarRoot {
  /// 今の項目の後ろに、左寄せで並ぶ部品——ブランチ名の札（前に区切り線。名前を省略して縮み、読める下限の幅も無ければ札ごと
  /// 落ちる）と、同期のボタン（同期・ブランチを公開。detached HEAD と初回コミットの前は出さない）。
  @ViewBuilder var changesMiddle: some View {
    if scm.isManaged == true {
      if let branch = ScmBranch(scm.branch) {
        HStack(spacing: Self.spacing) {
          EditorBarSeparator()
          ScmBranchChip(label: branch.label)
        }
        .editorBarPart(drops: .chip, grows: .chipWide)
      }
      if let sync = scm.syncState {
        ScmSyncButton(state: sync, sync: scm.sync, publish: scm.control.publish)
      }
    }
  }

  /// 右端に並ぶ部品——「コミット」（コミットのポップアップを開閉する。ステージ済みの行数を読めていれば、譲る添え書きに出す）。
  @ViewBuilder var changesTrailing: some View {
    if scm.isManaged == true {
      ScmCommitButton(
        counts: commitPopup.panel.stagedLines?.counts, isOpen: commitPopup.isOpen,
        toggle: commitPopup.toggle)
    }
  }
}

/// ブランチ名の札（表示だけ）。ブランチの印と名前（detached HEAD は短い sha）。名前は、幅が無ければ末尾を省略し、先頭の 4 字と
/// 「…」より狭くならない。
struct ScmBranchChip: View {
  let label: String

  var body: some View {
    EditorBarChip(
      help: label,
      content: {
        EditorGlyphView(
          glyph: EditorGlyphs.branch, size: Theme.Layout.editorBranchGlyph,
          color: Color.theme.textPrimary)
        EditorReadableName(
          label, prefixLength: Theme.Layout.editorBarChipReadablePrefix, truncation: .tail
        ) { Text($0) }
      })
  }
}

/// 同期のボタン（地つきの札）。「同期」と、先行・遅れの数（上向きの矢印と先行の数、下向きの矢印と遅れの数。0 の側は出さない）、
/// upstream が無ければ「ブランチを公開」。押すと同期（プル → プッシュ）か公開。ネット操作が走っている間と、upstream の ref が
/// 手元に無い間は薄い姿で押せない。説明と VoiceOver の名前は「同期 ↑2 ↓1」の形で、upstream の ref が無ければ「同期（upstream の
/// origin/feat がリモートにありません）」。
struct ScmSyncButton: View {
  let state: ScmSyncState
  let sync: () -> Void
  let publish: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorBarChip(
      style: .filled, isEnabled: state.isEnabled, help: help,
      action: {
        switch state.action {
        case .sync: sync()
        case .upstreamGone: break
        case .publish: publish()
        }
      },
      content: {
        switch state.action {
        case .sync(let divergence):
          Text(l10n.string(.editorScmSync))
          if let divergence { counts(divergence) }
        case .upstreamGone:
          Text(l10n.string(.editorScmSync))
        case .publish:
          Text(l10n.string(.editorScmPublish))
        }
      }
    )
    .fixedSize()
  }

  private var help: String {
    switch state.action {
    case .sync(let divergence?): l10n.string(.editorScmSync) + " " + divergence.arrows
    case .sync(nil): l10n.string(.editorScmSync)
    case .upstreamGone(let upstream): l10n.format(.editorScmSyncUpstreamGone, upstream)
    case .publish: l10n.string(.editorScmPublish)
    }
  }

  private func counts(_ divergence: GitStatus.Divergence) -> some View {
    HStack(spacing: Theme.Layout.editorBarChipFilledGap) {
      if divergence.ahead > 0 { count(EditorGlyphs.arrowUp, divergence.ahead) }
      if divergence.behind > 0 { count(EditorGlyphs.arrowDown, divergence.behind) }
    }
  }

  private func count(_ glyph: EditorGlyphs.Glyph, _ number: Int) -> some View {
    HStack(spacing: Theme.Layout.editorSyncArrowGap) {
      EditorGlyphView(
        glyph: glyph, size: Theme.Layout.editorBranchGlyph, color: Color.theme.textSecondary)
      Text("\(number)")
        .font(Font.theme.editorSyncCount)
        .foregroundStyle(Color.theme.textSecondary)
    }
  }
}

/// 右端の「コミット」。git 管理下と分かっている間はいつも押せる。開いている姿は、コミットのポップアップが開いている間
/// （`isOpen`）。ステージ済みの行数 `counts` を読めていれば、譲る添え書き「ステージ済み +125 −3」（追加は `diff.added`、削除は `diff.removed`）を
/// 付ける（0 の側は出さず、両方 0 なら「ステージ済み」だけ）。ツールチップは「コミット」、VoiceOver の名前は行数を読めていれば
/// 「コミット、ステージ済み +125 −3」の形（0 の側は同じく読まない）。
struct ScmCommitButton: View {
  let counts: GitLineCounts?
  let isOpen: Bool
  let toggle: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorBarActionButton(
      title: l10n.string(.editorScmCommit), isOpen: isOpen,
      help: l10n.string(.editorScmCommit), accessibilityName: counts.map(accessibilityName),
      action: toggle,
      detail: {
        if let counts {
          HStack(spacing: Theme.Space.note) {
            Text(l10n.string(.editorScmStagedDetail))
              .font(Font.theme.editorItemListHint)
              .foregroundStyle(Color.theme.textSecondary)
            HStack(spacing: Theme.Space.note) {
              if counts.added > 0 {
                Text(Self.added(counts)).foregroundStyle(Color.theme.diffAdded)
              }
              if counts.deleted > 0 {
                Text(Self.deleted(counts)).foregroundStyle(Color.theme.diffRemoved)
              }
            }
            .font(Font.theme.editorBarCount)
          }
        }
      })
  }

  private static func added(_ counts: GitLineCounts) -> String { "+\(counts.added)" }
  private static func deleted(_ counts: GitLineCounts) -> String { "−\(counts.deleted)" }

  /// 「コミット、ステージ済み +125 −3」（0 の側は入れず、両方 0 なら「コミット、ステージ済み」）。
  private func accessibilityName(_ counts: GitLineCounts) -> String {
    let numbers = [
      counts.added > 0 ? Self.added(counts) : nil, counts.deleted > 0 ? Self.deleted(counts) : nil,
    ].compactMap { $0 }
    return l10n.format(.editorScmCommitWithStaged, numbers.joined(separator: " "))
      .trimmingCharacters(in: .whitespaces)
  }
}
