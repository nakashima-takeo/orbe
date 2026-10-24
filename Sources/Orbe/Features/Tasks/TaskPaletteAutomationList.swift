import SwiftUI

/// 提案タブの本体。左に棚、真ん中に候補の一覧、右に選ばれている候補の詳細。棚はカードの幅の 1/4 で、狭い窓では下限で止めて
/// 真ん中を縮める。
struct TaskPaletteAutomationBody: View {
  @Bindable var model: TaskPaletteAutomationModel
  let detailWidth: CGFloat

  private static let minShelfWidth: CGFloat = 176

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        TaskPaletteAutomationShelf(model: model)
          .frame(width: max(Self.minShelfWidth, geometry.size.width / 4))
        rule
        TaskPaletteAutomationList(model: model)
        rule
        TaskPaletteAutomationDetail(model: model)
          .frame(width: detailWidth)
      }
    }
  }

  private var rule: some View {
    Rectangle().fill(Color.theme.surface1).frame(width: Theme.Stroke.hairline)
  }
}

/// 真ん中の候補の一覧。自動化を選んでいれば、頭に判定のノードごとの最新の回を出す。
struct TaskPaletteAutomationList: View {
  @Bindable var model: TaskPaletteAutomationModel
  @Environment(\.localization) private var l10n

  var body: some View {
    let proposals = model.proposals
    let list = model.proposalList
    VStack(alignment: .leading, spacing: 0) {
      if let automation = model.selectedAutomation { headline(automation) }
      if proposals.isEmpty {
        Text(l10n.string(.taskPaletteAutomationEmpty))
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textMuted)
          .padding(.horizontal, Theme.Space.phrase)
          .padding(.vertical, Theme.Space.beat)
        Spacer(minLength: 0)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.hair) {
              ForEach(proposals) { row($0) }
            }
            .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
            .padding(.top, model.selectedAutomation == nil ? Theme.Space.beat : 0)
            .padding(.bottom, Theme.Space.beat)
          }
          .scrollIndicators(.automatic)
          .onChange(of: list.scrollTarget) {
            if let id = list.scrollTarget?.id { proxy.scrollTo(id) }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// 判定のノードごとの最新の回を入力の深さ順に 1 行ずつ（「9:00 開発の依頼を選ぶ　候補 2 件」。失敗は赤で
  /// 「失敗：<説明>」）。狭い欄では各行を 2 行まで折り返す。
  private func headline(_ automation: Automation) -> some View {
    let text = AutomationText(l10n: l10n, today: model.today, timeZone: model.timeZone)
    let judges = automation.graph.byDepth.filter { $0.role == .judge }
    return VStack(alignment: .leading, spacing: 3) {
      ForEach(judges, id: \.id) { node in
        let run = automation.state(node.id).runs.first
        Text(Self.latest(node, run, text))
          .foregroundStyle(run?.failed == true ? Color.theme.danger : Color.theme.textMuted)
          .lineLimit(2)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(Font.theme.meta)
    .lineSpacing(2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.Space.phrase)
    .padding(.vertical, Theme.Space.step)
    .padding(.top, Theme.Space.tick)
  }

  /// 判定のノードの最新の回の 1 行。ノードは名前だけで言う。
  static func latest(
    _ node: AutomationGraph.Node, _ record: AutomationRunRecord?, _ text: AutomationText
  )
    -> String
  {
    let l10n = text.l10n
    guard let record else {
      return node.entity.name + "\u{3000}" + l10n.string(.taskPaletteAutomationNeverJudged)
    }
    let head = text.stamp(record.startedAt) + " " + node.entity.name + "\u{3000}"
    guard let run = record.run else {
      return head
        + l10n.string(record.failed ? .automationRunUnknownFailed : .automationRunUnknownPassed)
    }
    let result: String
    if let failure = run.failure {
      result = l10n.format(
        .automationFailedWith,
        text.failureHead(failure, ending: run.execution.ending, node: node))
    } else if case .judge(let proposed, _, _) = run.result, proposed > 0 {
      result = l10n.plural(
        proposed, one: .taskPaletteAutomationProposedCountOne,
        other: .taskPaletteAutomationProposedCountOther)
    } else {
      result = l10n.string(.automationNoProposals)
    }
    return head + result
  }

  private func row(_ proposal: AutomationProposal) -> some View {
    TaskPaletteAutomationProposalRow(
      proposal: proposal, originNodeName: model.originNodeName(of: proposal),
      text: AutomationText(l10n: l10n, today: model.today, timeZone: model.timeZone),
      selected: model.selectedProposal?.id == proposal.id
    )
    .contentShape(Rectangle())
    .onTapGesture { model.tapProposal(proposal.id) }
    .onHover { if $0 { model.hoverProposal(proposal.id) } }
    .id(proposal.id)
  }
}

/// 候補の行。タイトル・期限の札・右に時刻、下に出どころの取得のノードの名前と本文の先頭 1 行。印は選ばれている候補の行だけ。
private struct TaskPaletteAutomationProposalRow: View {
  let proposal: AutomationProposal
  let originNodeName: String?
  let text: AutomationText
  let selected: Bool
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      HStack(spacing: Theme.Space.step) {
        TruncatingSlot(proposal.title) {
          fontResolver.text($0, base: Theme.Typography.workspaceName)
            .font(Font.theme.workspaceName)
            .foregroundStyle(Color.theme.textPrimary)
        }
        .layoutPriority(1)
        if let due = proposal.due {
          TaskPaletteBadge(
            text: TaskDueText.label(
              due, today: text.today, weekdays: TaskDueText.weekdays(l10n.language)),
            foreground: Color.theme.textSecondary, fill: Color.theme.plainPillFill)
        }
        Spacer(minLength: Theme.Space.step)
        Text(text.short(proposal.item.time))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .fixedSize()
      }
      fontResolver.text(
        [originNodeName, Self.firstLine(proposal.item.body)].compactMap { $0 }.joined(
          separator: " · "),
        base: Theme.Typography.meta
      )
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
      .truncationMode(.tail)
    }
    .padding(.vertical, Theme.Space.step + Theme.Space.hair)
    .padding(.horizontal, Theme.Space.bar - Theme.Space.hair)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(selected ? Color.theme.selectionFill : .clear))
  }

  /// 本文の先頭 1 行（空の行は飛ばす）。
  static func firstLine(_ body: String) -> String {
    body.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
  }
}
