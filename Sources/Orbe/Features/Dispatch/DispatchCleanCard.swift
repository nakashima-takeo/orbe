import SwiftUI

/// Dispatch カードの clean モードの中身（ヘッダ中身・リスト部・フッター）。器は `DispatchCard` が持つ。
///
/// 3 画面（選択 / 削除中 / 一部失敗）は**同じ器の中身が入れ替わるだけ**で、枠・`❯`・高さの契約は共通。
/// 画面の別は `DispatchCleanModel.phase` が状態から導き、View は保存フラグを持たない。

/// clean のヘッダ中身（見出し＋右のピル）。`❯` と枠は両モード共通なので器の側にある。
struct DispatchCleanHeader: View {
  @Bindable var model: DispatchCleanModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step + Theme.Space.hair) {
      (Text("clean").foregroundStyle(Color.theme.textPrimary)
        + Text(" — " + subtitle).foregroundStyle(Color.theme.textMuted))
        .font(Font.theme.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: Theme.Space.step)
      switch model.phase {
      case .selecting:
        pill(
          l10n.format(.dispatchCleanSelected, model.selectedCount), Color.theme.tintAccent,
          .theme.accentPrimary)
        Text(l10n.string(.dispatchCleanBack))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .fixedSize()
      case .deleting:
        // 分子は決着した件数（成功＋失敗）。分母が総数なので、成功だけだと ✓/✕ の付いた行と食い違う。
        pill(
          l10n.format(.dispatchCleanProgress, model.settledCount, model.totalCount),
          Color.theme.tintAccent, .theme.accentPrimary)
      case .failed:
        pill(
          l10n.format(.dispatchCleanTally, model.doneCount, model.failedCount),
          CleanTone.danger.fill, CleanTone.danger.foreground)
      }
    }
  }

  /// 見出しの後半。件数はすべて実行順の配列から導く（リテラルの件数を持たない）。
  private var subtitle: String {
    switch model.phase {
    case .selecting: return l10n.string(.dispatchCleanSubtitle)
    case .deleting: return l10n.string(.dispatchCleanDeletingTitle)
    case .failed: return l10n.format(.dispatchCleanDoneTitle, model.failedCount)
    }
  }

  private func pill(_ text: String, _ background: Color, _ foreground: Color) -> some View {
    Text(text)
      .font(Font.theme.meta)
      .foregroundStyle(foreground)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .padding(.vertical, Theme.Space.hair + 1)
      .background(Capsule().fill(background))
  }
}

/// clean のリスト部。選択画面は群見出し付きの全 worktree、削除中と一部失敗は**選んだ行だけ**が
/// 実行順に並ぶ（未選択は畳んで非表示・群見出しは出さない）。
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
          if model.phase == .selecting {
            selection
          } else {
            run
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
      .onChange(of: model.scrollTargetID, initial: true) {
        guard let id = model.scrollTargetID else { return }
        proxy.scrollTo(id)
      }
    }
  }

  /// 選択画面。**空の群は見出しごと出さない**（list モードの規約と同じ）。
  @ViewBuilder private var selection: some View {
    let visible = Self.sections.filter { section in
      model.rows.contains { $0.group == section.group }
    }
    ForEach(Array(visible.enumerated()), id: \.element.group) { index, section in
      sectionLabel(section.key, warn: section.warn, first: index == 0)
      ForEach(model.rows.filter { $0.group == section.group }) { row in
        DispatchCleanRow(model: model, row: row)
      }
    }
  }

  /// 削除中・一部失敗。行も件数も実行順の配列だけから出る。
  @ViewBuilder private var run: some View {
    if let run = model.run {
      ForEach(Array(run.requests.enumerated()), id: \.element.path) { index, request in
        DispatchCleanRunRow(
          request: request, state: run.states[index],
          cursor: model.phase == .failed && model.failureTargetPath == request.path,
          showsActions: model.phase == .failed)
      }
    }
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

/// clean のフッター。画面ごとに案内が入れ替わる（効かない操作の案内を残さない）。
struct DispatchCleanFooter: View {
  @Bindable var model: DispatchCleanModel
  let onExecute: () -> Void
  let onClose: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.beat) {
      switch model.phase {
      case .selecting:
        Spacer(minLength: Theme.Space.step)
        hint(l10n.string(.dispatchCleanKeyHint))
        button(executeLabel, enabled: model.canExecute) { onExecute() }
      case .deleting:
        // 終端はここで言い切る（未選択の行は畳んだまま実行が終わる）。
        Text(l10n.string(.dispatchCleanCollapsedNote))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        hint(l10n.string(.dispatchCleanCancelHint))
      case .failed:
        Spacer(minLength: Theme.Space.step)
        hint(l10n.string(.dispatchCleanRetryAll))
        button(l10n.string(.dispatchCleanClose), enabled: true) { onClose() }
      }
    }
    .padding(.horizontal, Theme.Space.bar)
    .padding(.vertical, Theme.Space.step + Theme.Space.hair)
  }

  /// 実行ボタンの文言（＝実行の総量）。ブランチも消える行が選ばれているときだけ内訳を付ける
  /// ——0 件の内訳はノイズなので、無いときは worktree 数だけを言う。
  ///
  /// 件数付きの名詞は**断片として `plural` で組んでから**テンプレートへ差す（`%@` は損失の内訳と
  /// 同じ組み方）。2 つの数がそれぞれ単複を持つので、テンプレート側に数を渡すとキーが組合せで増える。
  private var executeLabel: String {
    let worktrees = l10n.plural(
      model.selectedCount, one: .dispatchCleanExecuteWorktreesOne,
      other: .dispatchCleanExecuteWorktreesOther)
    guard model.branchDeleteCount > 0 else {
      return l10n.format(.dispatchCleanExecute, worktrees)
    }
    let branches = l10n.plural(
      model.branchDeleteCount, one: .dispatchCleanExecuteBranchesOne,
      other: .dispatchCleanExecuteBranchesOther)
    return l10n.format(.dispatchCleanExecuteWithBranches, worktrees, branches)
  }

  /// 狭窓で最初に譲るのはキーヒント（実行ボタンは効く操作なので削らない）。
  private func hint(_ text: String) -> some View {
    Text(text)
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
      .truncationMode(.tail)
      .layoutPriority(1)
  }

  private func button(_ text: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Text(text)
      .font(Font.theme.paneRow)
      .foregroundStyle(Color.theme.accentBright)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.beat)
      .padding(.vertical, 3)
      .background(Capsule().fill(Color.theme.accentPrimary.opacity(0.16)))
      .opacity(enabled ? 1 : Theme.Opacity.disabled)
      .contentShape(Capsule())
      .onTapGesture { if enabled { action() } }
  }
}
