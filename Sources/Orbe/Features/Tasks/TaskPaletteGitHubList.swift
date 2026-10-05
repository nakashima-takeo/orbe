import SwiftUI

/// GitHub タブの左の一覧。上に絞り込みの札、その下に区分ごとの行。行は `TaskPaletteGitHubRows` が組んだ値を
/// そのまま描き、選択は行の同一性で光らせる。使えないとき・読み込み中は理由の 1 行だけを出す。
struct TaskPaletteGitHubList: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    switch model.gitHubBody {
    case .lists:
      VStack(alignment: .leading, spacing: 0) {
        TaskGitHubFilterChips(model: model)
          .padding(.leading, 22 + 11)
          .padding(.top, Theme.Space.span)
          .padding(.bottom, Theme.Space.step)
        rows
      }
    case .loading: line(.taskPaletteGitHubLoading)
    case .failed: line(.taskPaletteGitHubFailed)
    case .unavailable(let reason): line(Self.reasonKey(reason))
    }
  }

  private var rows: some View {
    let rows = model.gitHubRows
    let list = model.gitHubList
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row($0) }
        }
        .padding(.bottom, Theme.Space.beat)
        .padding(.leading, 11)
        .padding(.trailing, 10)
      }
      .scrollIndicators(.automatic)
      .onChange(of: list.scrollTarget) { scroll(proxy, to: list.scrollTarget?.id) }
      .onAppear { scroll(proxy, to: list.selectedID) }
    }
  }

  private func scroll(_ proxy: ScrollViewProxy, to id: TaskPaletteGitHubRowID?) {
    if let id { proxy.scrollTo(TaskPaletteGitHubRow.Identity.selectable(id)) }
  }

  private func line(_ key: L10nKey) -> some View {
    Text(l10n.string(key))
      .font(Font.theme.chrome)
      .foregroundStyle(Color.theme.textMuted)
      .padding(.leading, 22 + 11)
      .padding(.top, Theme.Space.span)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  static func reasonKey(_ reason: GitHubRepositoryUnavailable) -> L10nKey {
    switch reason {
    case .ghMissing: .taskPaletteGitHubGhMissing
    case .ghUnauthed: .taskPaletteGitHubGhUnauthed
    case .notFound: .taskPaletteGitHubNotFound
    }
  }

  @ViewBuilder private func row(_ row: TaskPaletteGitHubRow) -> some View {
    switch row {
    case .header(let kind, let count):
      sectionLabel(kind, count)
    case .item(let item):
      TaskPaletteGitHubItemRowView(
        row: item, selected: model.selectedGitHubID == .item(item.id),
        onTap: { model.tapGitHubRow(.item(item.id)) },
        onHoverEnter: { model.hoverGitHubRow(.item(item.id)) })
    case .more(let kind, let count):
      TaskPaletteRowFrame(
        selected: model.selectedGitHubID == .more(kind), height: 30,
        onTap: { model.tapGitHubRow(.more(kind)) },
        onHoverEnter: { model.hoverGitHubRow(.more(kind)) },
        content: {
          Text("↓ " + l10n.format(.taskPaletteGitHubMore, count))
            .font(Font.theme.chrome)
            .foregroundStyle(Color.theme.textMuted)
            .padding(.leading, 14 + Theme.Space.beat)
          Spacer(minLength: 0)
        })
    case .loading:
      Text(l10n.string(.commonLoading))
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.leading, 22 + 14 + Theme.Space.beat)
        .frame(height: 30)
    case .empty:
      Text(l10n.string(.taskPaletteGitHubEmpty))
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.leading, 22)
        .frame(height: 40)
    }
  }

  /// 「ISSUES · ORBE 24」。リポジトリ名は owner を除く。
  private func sectionLabel(_ kind: GitHubItemKind, _ count: Int) -> some View {
    let title = kind == .issue ? "ISSUES" : "PULL REQUESTS"
    let repo = model.gitHubRepo?.name.uppercased() ?? ""
    return Text("\(title) · \(repo) \(count)")
      .font(Font.theme.codeCompact)
      .tracking(1.5)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
      .padding(.leading, 22)
      .padding(.top, Theme.Space.beat)
      .padding(.bottom, Theme.Space.step)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 絞り込みの札（すべて / 担当が自分 / 作成者が自分 / レビュー依頼）。件数は一覧の全件で数え、自分がまだ
/// 分からない札には出さない。焦点は取らない。
struct TaskGitHubFilterChips: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    let counts = model.gitHubFilterCounts
    HStack(spacing: Theme.Space.step) {
      chip(.all, l10n.string(.taskPaletteScopeAll), nil)
      chip(.assigned, l10n.string(.taskPaletteGitHubFilterAssigned), counts?.assigned)
      chip(.authored, l10n.string(.taskPaletteGitHubFilterAuthored), counts?.authored)
      chip(.reviewRequested, l10n.string(.taskPaletteGitHubFilterReview), counts?.reviewRequested)
    }
  }

  private func chip(_ filter: TaskGitHubFilter, _ title: String, _ count: Int?) -> some View {
    let selected = model.githubFilter == filter
    return Button {
      model.setGitHubFilter(filter)
    } label: {
      HStack(spacing: Theme.Space.note) {
        Text(title)
          .foregroundStyle(selected ? Color.theme.textPrimary : Color.theme.textSecondary)
        if let count {
          Text("\(count)").foregroundStyle(Color.theme.textMuted)
        }
      }
      .font(Font.theme.code)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.beat)
      .frame(height: 26)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .fill(selected ? Color.theme.tintAccent : Color.theme.surfaceInk.opacity(0.04))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
  }
}

/// GitHub タブの項目の行。印・番号・タイトル・関係の文、右に結び付いたタスク（結び付いた行は地を薄く塗る）。
/// 縮むのはタイトルが先。
struct TaskPaletteGitHubItemRowView: View {
  let row: TaskPaletteGitHubItemRow
  let selected: Bool
  let onTap: () -> Void
  let onHoverEnter: () -> Void
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    TaskPaletteRowFrame(selected: selected, onTap: onTap, onHoverEnter: onHoverEnter) {
      TaskLinkGlyph(kind: row.item.kind)
        .frame(width: 14)
      Text("#\(row.item.number)")
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize()
        .padding(.leading, Theme.Space.beat)
      TruncatingSlot(row.item.title, leading: Theme.Space.step) {
        fontResolver.text($0, base: Theme.Typography.taskText)
          .font(Font.theme.taskText)
          .foregroundStyle(Color.theme.textPrimary)
      }
      .layoutPriority(1)
      if let relation = TaskGitHubRelationText.text(row.relation, l10n) {
        Text(relation)
          .font(Font.theme.chrome)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .fixedSize()
          .padding(.leading, Theme.Space.beat)
      }
      Spacer(minLength: Theme.Space.beat)
      if let task = row.task {
        TruncatingSlot(task.label, leading: 0) {
          (Text(Image(systemName: "link")).font(.system(size: 10, weight: .semibold)) + Text(" ")
            + fontResolver.text($0, base: Theme.Typography.codeCompact))
            .font(Font.theme.codeCompact)
            .foregroundStyle(Color.theme.accentBright)
        }
        .layoutPriority(0.5)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(row.task == nil ? .clear : Color.theme.surfaceInk.opacity(0.035))
    )
    .padding(.vertical, row.task == nil ? 0 : 2)
  }
}

/// 関係の文（「担当: あなた」「レビュー依頼 · @orbe/core 宛」「@tanaka」など）。
enum TaskGitHubRelationText {
  static func text(_ relation: TaskGitHubRelation, _ l10n: LocalizationStore) -> String? {
    switch relation {
    case .reviewRequestedYou: l10n.string(.taskPaletteRelationReviewYou)
    case .reviewRequestedTeam(let team):
      team.map { l10n.format(.taskPaletteRelationReviewTeam, $0) }
        ?? l10n.string(.taskPaletteRelationReview)
    case .authoredByYou: l10n.string(.taskPaletteRelationAuthoredYou)
    case .author(let login): login.map { "@\($0)" }
    case .assignedYou: l10n.string(.taskPaletteRelationAssignedYou)
    case .unassigned: l10n.string(.taskPaletteRelationUnassigned)
    case .assignee(let login): "@\(login)"
    }
  }
}
