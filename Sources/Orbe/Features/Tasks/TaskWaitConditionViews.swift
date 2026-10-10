import SwiftUI

/// 行の解けた待ちの札（「レビューが付いた 2分前」）。1 行で、文字の札の上限幅を超えれば末尾を省略する。経過は 1 分ごとに
/// 描き直す。
struct TaskResolvedBadge: View {
  let resolved: TaskPaletteTaskRow.Resolved
  /// 経過を数える今（`TaskPaletteModel.clock`）。
  let clock: (Date) -> Date
  @Environment(\.localization) private var l10n

  var body: some View {
    TimelineView(.periodic(from: resolved.at, by: 60)) { context in
      (Text(TaskWaitText.headline(resolved.headline, l10n: l10n))
        .foregroundStyle(Color.theme.accentBright)
        + Text(" " + TaskWaitText.ago(resolved.at, now: clock(context.date), l10n: l10n))
        .foregroundStyle(Color.theme.textMuted))
        .font(Font.theme.meta)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: TaskPaletteRowMetrics.textBadgeMaxWidth, alignment: .leading)
        .fixedSize()
        .padding(.horizontal, Theme.Space.step)
        .frame(height: TaskPaletteRowMetrics.firstLine)
        .background(Capsule().fill(Color.theme.tintAccent))
    }
  }
}

/// 右の欄の上部の会話の行（「claude 2日前の会話 · タブ pr-214」と「↗ タブへ」の 1 行）。会話のタブがあるときだけ止まる
/// 場所になり、↵ かクリックでそのタブへ移る。
struct TaskConversationRow: View {
  let conversation: WaitConversation
  let tab: AgentSessionTabs.Tab?
  /// 条件を付けた日から今日までの暦日の差。
  let days: Int
  let focused: Bool
  let onGoToTab: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      Text(conversation.command)
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textSecondary)
        .fixedSize()
      Text(TaskWaitText.conversation(days: days, l10n: l10n))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize()
      if let tab {
        Text("· " + l10n.format(.taskPaletteAgentTab, tab.title))
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textMuted)
          .truncationMode(.tail)
      }
      Spacer(minLength: Theme.Space.step)
      if tab != nil { TaskGoToTabChip() }
    }
    .lineLimit(1)
    .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
    .padding(.vertical, Theme.Space.step)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.md)
        .fill(focused ? Color.theme.selectionFill : Color.theme.surfaceInk.opacity(0.04))
    )
    .contentShape(Rectangle())
    .onTapGesture { if tab != nil { onGoToTab() } }
  }
}

/// 「↗ タブへ」の札（agent の場所と会話の行が共有する）。
struct TaskGoToTabChip: View {
  @Environment(\.localization) private var l10n

  var body: some View {
    Text("↗ " + l10n.string(.taskPaletteAgentGoToTab))
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textSecondary)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.note)
      .frame(height: 18)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.sm + 1)
          .fill(Color.theme.surfaceInk.opacity(0.06)))
  }
}

/// 待ちの項目の直下の箱（条件・確認の間隔と次・期限・開閉する「› 確認のコマンド」「› 実行の記録」）。値は画面から
/// 変えられない（変えたいときは AI に頼み直す）。「次は」は 1 分ごとに描き直す。
struct TaskConditionBox: View {
  @Bindable var model: TaskPaletteModel
  let condition: WaitCondition
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.hair) {
      TimelineView(.periodic(from: condition.anchor, by: 60)) { context in
        Grid(
          alignment: .leadingFirstTextBaseline,
          horizontalSpacing: Theme.Space.step + Theme.Space.hair, verticalSpacing: Theme.Space.hair
        ) {
          line(.taskWaitConditionLabel, condition.description)
          line(.taskWaitCheckLabel, every(now: model.clock(context.date)))
          line(.taskWaitDeadlineLabel, deadline)
        }
      }
      disclosure(.command, title: l10n.string(.taskWaitCommand)) {
        Text(condition.command)
          .foregroundStyle(Color.theme.textSecondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      disclosure(.log, title: l10n.string(.taskWaitLog) + " \(condition.checks)") {
        logLines
      }
    }
    .font(Font.theme.workspaceName)
    .padding(.horizontal, Self.inset)
    .padding(.vertical, Theme.Space.step)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.theme.surfaceInk.opacity(0.04)))
  }

  private static let inset = Theme.Space.step + Theme.Space.hair

  /// ラベルと値（ラベルの列は最も長いラベルの幅）。
  private func line(_ label: L10nKey, _ value: String) -> some View {
    GridRow {
      Text(l10n.string(label))
        .foregroundStyle(Color.theme.textMuted)
      Text(value)
        .foregroundStyle(Color.theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
    }
  }

  /// 「10 分ごと · 次は 7 分後」。期限までにもう確かめないなら「10 分ごと · 期限まで確認なし」。
  private func every(now: Date) -> String {
    guard let next = condition.nextCheck(now: now, calendar: .current) else {
      return l10n.format(.taskWaitEveryUntilDeadline, condition.everyMinutes)
    }
    let minutes = Int((next.timeIntervalSince(now) / 60).rounded(.up))
    return l10n.format(
      .taskWaitEvery, condition.everyMinutes,
      minutes > 0 ? l10n.format(.taskWaitNextIn, minutes) : l10n.string(.taskWaitSoon))
  }

  private var deadline: String {
    let day = TaskItem.DueDate(condition.deadline, timeZone: model.timeZone)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = model.timeZone
    let time = calendar.dateComponents([.hour, .minute], from: condition.deadline)
    return l10n.format(
      .taskWaitDeadline, TaskDueText.date(day, today: model.today),
      TaskDueText.weekdays(l10n.language)[day.weekday],
      String(format: "%d:%02d", time.hour!, time.minute!))
  }

  /// 開閉する部分（止まる場所）。↵ かクリックで開閉する。
  private func disclosure<Content: View>(
    _ part: TaskConditionPart, title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    let open = model.isConditionPartOpen(part)
    return VStack(alignment: .leading, spacing: Theme.Space.tick) {
      HStack(spacing: Theme.Space.tick) {
        Text("›")
          .rotationEffect(.degrees(open ? 90 : 0))
        Text(title)
        Spacer(minLength: 0)
      }
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .frame(height: 18)
      .padding(.horizontal, Theme.Space.tick)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.sm + 1)
          .fill(
            model.area == .detail(.condition(part)) ? Color.theme.selectionFill : .clear)
      )
      .padding(.horizontal, -Theme.Space.tick)
      .contentShape(Rectangle())
      .onTapGesture { model.toggleConditionPart(part) }
      if open {
        content()
          .font(Font.theme.meta)
          .padding(.leading, Theme.Space.beat)
          .padding(.bottom, Theme.Space.tick)
      }
    }
    .id(TaskDetailStop.condition(part))
  }

  /// 実行の記録（新しい順に「時刻 · 結果 · 標準出力〔無ければ標準エラー〕の先頭」）。
  @ViewBuilder private var logLines: some View {
    if condition.log.isEmpty {
      Text(l10n.string(.taskWaitLogEmpty)).foregroundStyle(Color.theme.textMuted)
    } else {
      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        ForEach(Array(condition.log.reversed().enumerated()), id: \.offset) { _, check in
          Text(
            [
              TaskDueText.stamp(check.startedAt, model.timeZone, today: model.today),
              TaskWaitText.result(check.result, l10n: l10n),
            ]
            .joined(separator: " · ")
              + (TaskWaitText.head(check).map { " · " + $0 } ?? "")
          )
          .foregroundStyle(
            check.result == .success ? Color.theme.textSecondary : Color.theme.textMuted
          )
          .lineLimit(1)
          .truncationMode(.tail)
        }
      }
    }
  }
}

/// 右の欄の上部の起きたことの箱（「● レビューが付いた 2分前 · 確認 18 回目」・確認の出力の続き・「⌘T claude で続きから」）。
struct TaskResolvedBox: View {
  let model: TaskPaletteModel
  let resolution: WaitResolution
  /// 続きから始められる会話（無ければボタンを出さない）。
  let continuation: WaitConversation?
  /// 会話があるのに続きから始められない理由（ボタンの代わりに出す）。
  let blocked: TaskPaletteError?
  @Environment(\.localization) private var l10n

  var body: some View {
    TimelineView(.periodic(from: resolution.at, by: 60)) { context in
      VStack(alignment: .leading, spacing: Theme.Space.note) {
        // 欄が狭くて 1 行に収まらなければ、経過と確認の回数を次の行へ送る。
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Theme.Space.note) {
            dot
            headline.fixedSize()
            meta(now: model.clock(context.date)).fixedSize()
          }
          VStack(alignment: .leading, spacing: Theme.Space.hair) {
            HStack(spacing: Theme.Space.note) {
              dot
              headline
            }
            meta(now: model.clock(context.date)).padding(.leading, Self.indent)
          }
        }
        if !resolution.restOfOutput.isEmpty {
          Text(resolution.restOfOutput.joined(separator: "\n"))
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
            .lineLimit(6)
            .padding(.leading, Self.indent)
        }
        if let continuation {
          continueButton(continuation)
        } else if let blocked {
          Text(l10n.format(.taskPaletteContinueBlocked, l10n.string(blocked.message)))
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, Self.indent)
        }
      }
      .padding(.horizontal, Theme.Space.beat)
      .padding(.vertical, Theme.Space.step + Theme.Space.hair)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.theme.tintAccent))
    }
  }

  private var dot: some View {
    Circle().fill(Color.theme.accentBright).frame(width: 6, height: 6)
  }

  private var headline: some View {
    Text(TaskWaitText.headline(resolution.headline, l10n: l10n))
      .font(Font.theme.workspaceName)
      .foregroundStyle(Color.theme.textPrimary)
      .lineLimit(1)
  }

  /// 「2分前 · 確認 18 回目」。
  private func meta(now: Date) -> some View {
    Text(
      l10n.format(
        .taskWaitResolvedChecks, TaskWaitText.ago(resolution.at, now: now, l10n: l10n),
        resolution.waiting.condition?.checks ?? 0)
    )
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.textMuted)
    .lineLimit(1)
  }

  /// 点の列の幅（点と間）。続きの行の書き出しを起きたことにそろえる。
  private static let indent: CGFloat = 6 + Theme.Space.note

  private func continueButton(_ conversation: WaitConversation) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      Button {
        model.continueWait()
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text("⌘T").foregroundStyle(Color.theme.accentBright)
          Text(l10n.format(.taskWaitContinue, conversation.command))
            .foregroundStyle(Color.theme.textPrimary)
        }
        .font(Font.theme.workspaceName)
        .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
        .frame(height: TaskPaletteFieldMetrics.buttonHeight)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.theme.tintAccent)
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
      Text(
        l10n.format(
          .taskWaitContinueNote,
          TaskWaitText.conversation(
            days: model.days(since: resolution.waiting.condition?.setAt ?? resolution.at),
            l10n: l10n))
      )
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
    }
    .padding(.leading, Self.indent)
    .padding(.top, Theme.Space.hair)
  }
}

/// 待ちの条件の文字（起きたこと・経過・時刻・確認の結果）。
enum TaskWaitText {
  /// 起きたこと（`WaitResolution.headline`）。期限なら「期限が来た」、出力が空なら「条件を満たした」。
  static func headline(_ headline: String?, l10n: LocalizationStore) -> String {
    guard let headline else { return l10n.string(.taskWaitExpired) }
    return headline.isEmpty ? l10n.string(.taskWaitSatisfied) : headline
  }

  /// 「2分前」（1 分未満は「たった今」）。
  static func ago(_ date: Date, now: Date, l10n: LocalizationStore) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return l10n.string(.taskWaitJustNow) }
    return l10n.format(.taskWaitAgo, TaskElapsedText.label(since: date, now: now, l10n: l10n))
  }

  /// 「2日前の会話」「今日の会話」。
  static func conversation(days: Int, l10n: LocalizationStore) -> String {
    days == 0
      ? l10n.string(.taskWaitConversationToday) : l10n.format(.taskWaitConversationDays, days)
  }

  static func result(_ result: WaitCheck.Result, l10n: LocalizationStore) -> String {
    switch result {
    case .success: l10n.string(.taskWaitResultSuccess)
    case .exited(let code): l10n.format(.taskWaitResultExited, Int(code))
    case .signaled(let signal): l10n.format(.taskWaitResultSignaled, Int(signal))
    case .limited: l10n.string(.taskWaitResultLimited)
    case .stopped: l10n.string(.taskWaitResultStopped)
    case .notStarted: l10n.string(.taskWaitResultNotStarted)
    }
  }

  /// 記録の先頭の 1 行（標準出力、無ければ標準エラー、始められなかったなら理由）。
  static func head(_ check: WaitCheck) -> String? {
    if case .notStarted(let reason) = check.result { return reason }
    return WaitText.lines(check.stdout).first ?? WaitText.lines(check.stderr).first
  }
}
