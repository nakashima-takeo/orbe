import SwiftUI

/// Dispatch カードの clean モードの中身（ヘッダ中身・リスト部・フッター）。器は `DispatchCard` が持つ。

/// clean のヘッダ中身（見出し＋選択数チップ＋`esc 戻る`）。`❯` と枠は両モード共通なので器の側にある。
struct DispatchCleanHeader: View {
  @Bindable var model: DispatchCleanModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      (Text("clean").foregroundStyle(Color.theme.textPrimary)
        + Text(" — " + l10n.string(.dispatchCleanSubtitle))
        .foregroundStyle(Color.theme.textMuted))
        .font(Font.theme.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Space.step)
      Text(l10n.format(.dispatchCleanSelected, model.selectedCount))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.accentPrimary)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
        .padding(.vertical, Theme.Space.hair + 1)
        .background(Capsule().fill(Color.theme.tintAccent))
      Text(l10n.string(.dispatchCleanBack))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .fixedSize()
    }
  }
}

/// clean のリスト部（3 セクション・群順固定）。**全 worktree を出す。危険なものも一覧から消さない。**
struct DispatchCleanList: View {
  @Bindable var model: DispatchCleanModel
  @Environment(\.localization) private var l10n

  /// 群見出しの並びと語彙（safe → caution → inUse の固定順）。
  private struct Section {
    let group: CleanGroup
    let key: L10nKey
    /// caution だけ警告色で出す。
    var warn = false
  }

  private static let sections: [Section] = [
    Section(group: .safe, key: .dispatchCleanSectionSafe),
    Section(group: .caution, key: .dispatchCleanSectionCaution, warn: true),
    Section(group: .inUse, key: .dispatchCleanSectionInUse),
  ]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(Self.sections.enumerated()), id: \.element.group) { index, section in
            sectionLabel(section.key, warn: section.warn, first: index == 0)
            ForEach(model.rows.filter { $0.group == section.group }) { row in
              DispatchCleanRow(
                row: row, selection: model.state(of: row),
                cursor: model.cursorRow?.id == row.id,
                onTap: { model.advance(at: row.id) })
            }
          }
        }
        .padding(Theme.Space.note)
        .background(
          GeometryReader { geometry in
            Color.clear.preference(key: DispatchContentHeightKey.self, value: geometry.size.height)
          }
        )
      }
      .scrollIndicators(.automatic)
      .onChange(of: model.cursor, initial: true) { scrollToCursor(proxy) }
    }
  }

  /// カーソル行を可視域へ追従させる（list 側の `scrollToSelection` と同じ作法。宛先は行 id＝絶対パス）。
  private func scrollToCursor(_ proxy: ScrollViewProxy) {
    guard let id = model.cursorRow?.id else { return }
    proxy.scrollTo(id)
  }

  /// 群見出し（選択対象外・大文字・極小・letterSpacing 1）。caution だけ警告色。
  private func sectionLabel(_ key: L10nKey, warn: Bool, first: Bool) -> some View {
    Text(l10n.string(key).uppercased())
      .font(Font.theme.paneSegment)
      .tracking(Theme.Typography.trackingLabel)
      .foregroundStyle(warn ? Color.theme.stateWaiting : Color.theme.textMuted)
      .padding(.top, first ? Theme.Space.step : 10)
      .padding(.horizontal, 10)
      .padding(.bottom, 3)
  }
}

/// clean の 1 行。チェック・名前・パス・群ごとのチップ列。
/// **背景ハイライトはカーソル行だけ**——チェック状態は ✓ ボックスの塗りだけで示す（背景で二重に示さない）。
struct DispatchCleanRow: View {
  let row: CleanRow
  let selection: CleanSelection
  let cursor: Bool
  let onTap: () -> Void
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  private var inUse: Bool { row.group == .inUse }

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      checkbox
      fontResolver.text(row.name, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(cursor ? Color.theme.textPrimary : Color.theme.textSecondary)
        .lineLimit(1)
        .fixedSize()
      fontResolver.text(row.meta, base: Theme.Typography.meta)
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 5) {
        ForEach(row.chips) { DispatchCleanChip(chip: $0) }
        if let word = selectionWord {
          Text(l10n.string(word.key))
            .font(Font.theme.sectionLabel)
            .foregroundStyle(word.color)
            .lineLimit(1)
        }
      }
      .fixedSize()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(cursor ? Color.theme.selectionFill : .clear)
    )
    .opacity(inUse ? 0.6 : 1)
    .contentShape(Rectangle())
    .onTapGesture { if !inUse { onTap() } }
    .id(row.id)
  }

  /// 13×13 のチェックボックス。**3 状態をボックスで描き分けない**（13px では判別できない）——
  /// `worktree のみ` と `worktree + ブランチ` の別は行末の語が読ませる。
  @ViewBuilder private var checkbox: some View {
    if inUse {
      // inUse 行はボックス自体を描かず、同幅の空スペーサで名前の頭を揃える。
      Color.clear.frame(width: 13, height: 13)
    } else if selection == .none {
      RoundedRectangle(cornerRadius: 3.5)
        .strokeBorder(Color.theme.borderInk.opacity(0.35), lineWidth: Theme.Stroke.hairline)
        .frame(width: 13, height: 13)
    } else {
      RoundedRectangle(cornerRadius: 3.5)
        .fill(Color.theme.accentPrimary)
        .frame(width: 13, height: 13)
        .overlay(
          Text("✓")
            .font(Font.theme.paneSegment)
            .foregroundStyle(Color.theme.accentCheckStroke))
    }
  }

  /// caution 行だけが出す選択状態の語（safe 行はフッタのトグルが全行へ一律に示すので重ねて言わない）。
  private var selectionWord: (key: L10nKey, color: Color)? {
    guard row.group == .caution else { return nil }
    switch selection {
    case .none: return nil
    case .worktreeOnly: return (.dispatchCleanWorktreeOnly, Color.theme.textMuted)
    case .worktreeAndBranch:
      return (.dispatchCleanWorktreeAndBranch, Color.theme.stateWaiting)
    }
  }
}

/// clean の行末チップ。地ありの 3 種（merged=緑 / plain=灰 / caution=琥珀）と、地なしの注記。
/// **git の語彙（`[gone]` / `merged` / `locked` / `clean · +0` / `main worktree`）は L10n しない**——
/// 訳すと git の出力と対応が取れなくなる技術語なので、`origin/…` と同じくそのまま出す。
struct DispatchCleanChip: View {
  let chip: CleanChip
  @Environment(\.localization) private var l10n

  var body: some View {
    switch chip {
    case .mergedPR(let number):
      filled("PR #\(number) merged", Color.theme.tintDiffAdded, .theme.diffAdded)
    case .gone:
      filled("[gone]", Color.theme.plainPillFill, .theme.textMuted)
    case .prunable:
      filled(l10n.string(.dispatchCleanPrunable), Color.theme.plainPillFill, .theme.textMuted)
    case .dirty:
      caution(l10n.string(.dispatchCleanDirty))
    case .unmergedClosed(let count):
      caution(l10n.format(.dispatchCleanUnmergedClosed, count))
    case .ownCommits(let count):
      caution(l10n.format(.dispatchCleanOwnCommits, count))
    case .locked:
      caution("locked")
    case .cleanNote:
      note("clean · +0", .theme.diffAdded)
    case .mainWorktree:
      note("main worktree", .theme.textMuted)
    case .paneOpen(let working):
      HStack(spacing: 5) {
        if working { StatusGlyphView(kind: .working, size: 11) }
        note(
          l10n.string(working ? .dispatchCleanPaneBusy : .dispatchCleanPaneOpen),
          .theme.textMuted)
      }
    }
  }

  private func filled(_ text: String, _ background: Color, _ foreground: Color) -> some View {
    Text(text)
      .font(Font.theme.sectionLabel)
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 1)
      .background(Capsule().fill(background))
  }

  private func caution(_ text: String) -> some View {
    filled(text, Color.theme.tintWaiting, .theme.stateWaiting)
  }

  private func note(_ text: String, _ color: Color) -> some View {
    Text(text).font(Font.theme.sectionLabel).foregroundStyle(color).lineLimit(1)
  }
}

/// clean のフッター。ブランチ削除トグル・キーヒント・実行ボタン。
/// 実行中は既存 Dispatch の「作成中」と同語彙でスピナ＋ラベルだけにし、効かない案内を残さない。
struct DispatchCleanFooter: View {
  @Bindable var model: DispatchCleanModel
  let onExecute: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.beat) {
      if model.isDeleting {
        HStack(spacing: Theme.Space.note) {
          StatusGlyphView(kind: .working, size: 10)
          Text(l10n.string(.dispatchCleanDeleting))
            .font(Font.theme.paneRow)
            .foregroundStyle(Color.theme.textMuted)
        }
        Spacer(minLength: 0)
      } else {
        branchToggle
        if let error = model.errorMessage {
          Text(error)
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.danger)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Spacer(minLength: Theme.Space.step)
        }
        Text(l10n.string(.dispatchCleanKeyHint))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .fixedSize()
        executeButton
      }
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.step + Theme.Space.hair)
  }

  /// `ローカルブランチも削除`（既定 ON）。**効くのは safe 行だけ**（caution 行は行ごとの状態が決める）。
  private var branchToggle: some View {
    HStack(spacing: 7) {
      ZStack(alignment: model.deleteBranch ? .trailing : .leading) {
        Capsule()
          .fill(
            model.deleteBranch
              ? Color.theme.accentPrimary.opacity(0.35) : Color.theme.surfaceInk.opacity(0.1)
          )
          .frame(width: 22, height: 12)
        Circle()
          .fill(model.deleteBranch ? Color.theme.accentPrimary : Color.theme.textMuted)
          .frame(width: 8, height: 8)
          .padding(.horizontal, Theme.Space.hair)
      }
      Text(l10n.string(.dispatchCleanDeleteBranch))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .fixedSize()
    }
    .contentShape(Rectangle())
    .onTapGesture { model.deleteBranch.toggle() }
  }

  private var executeButton: some View {
    Text(l10n.format(.dispatchCleanExecute, model.selectedCount))
      .font(Font.theme.paneRow)
      .foregroundStyle(Color.theme.accentBright)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.beat)
      .padding(.vertical, 3)
      .background(Capsule().fill(Color.theme.accentPrimary.opacity(0.16)))
      .opacity(model.canExecute ? 1 : Theme.Opacity.disabled)
      .contentShape(Capsule())
      .onTapGesture { if model.canExecute { onExecute() } }
  }
}
