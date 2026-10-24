import Foundation

/// 回の失敗と外れた行の、画面の言い方。種類から説明を引き、日本語の画面では AI が読む英文（原文）を括弧で添える。原文は
/// 英語なので、英語の画面では原文を重ねず（説明と同じことを 2 度言うため）、原文にだけある抜粋（標準エラー・最初の外れた
/// 行）を「説明: 抜粋」で添える。Orbe が種類を決められない文（部品の申告・CLI のエラー）は、説明の頭の後に文をそのまま
/// 添え、原文を重ねない。
extension AutomationText {
  /// 「制限時間を超過（the node "x" ended: stopped at the time limit）」。
  func failure(_ run: AutomationNodeRun, node: AutomationGraph.Node) -> String? {
    guard let failure = run.failure else { return nil }
    let head = failureHead(failure, ending: run.execution.ending, node: node)
    switch failure {
    case .agentError, .reported: return head
    case _ where l10n.language == .en:
      return excerpt(failure, breach: run.breach).map {
        l10n.format(.automationLabeled, head, $0)
      } ?? head
    default:
      let original = failure.text(
        nodeKey: node.key, ending: run.execution.ending, breach: run.breach)
      return l10n.format(.automationWithOriginal, head, original)
    }
  }

  /// 定義を読めない理由（「定義エラー（nodes[0].trigger: …）」。英語の画面は「: 」で添える）。
  func unreadable(_ reason: String) -> String {
    let head = l10n.string(.boardAutomationUnreadable)
    return l10n.language == .en
      ? l10n.format(.automationLabeled, head, reason)
      : l10n.format(.automationWithOriginal, head, reason)
  }

  /// 説明が言わず、原文にだけある抜粋（標準エラーか応答の抜粋・最初の外れた件）。無ければ nil。
  private func excerpt(_ failure: AutomationFailure, breach: AutomationRejections?) -> String? {
    switch failure {
    case .ended(let detail), .noReply(let detail): detail.isEmpty ? nil : detail
    case .brokeRules: breach?.lines.first.map(line)
    case .notUTF8, .agentError, .reported, .unsourced, .unreadInput, .noResult: nil
    }
  }

  /// 失敗の説明だけ（原文を添えない。狭い欄の 1 行）。
  func failureHead(
    _ failure: AutomationFailure, ending: AutomationEnding, node: AutomationGraph.Node
  ) -> String {
    switch failure {
    case .ended: return self.ending(ending)
    case .noReply: return l10n.string(.automationFailNoReply)
    case .notUTF8: return l10n.string(.automationFailNotUTF8)
    case .agentError(let text):
      var cli = ""
      if case .agent(let agent) = node.action.method { cli = agent.cli }
      return l10n.format(.automationFailAgentError, cli, text)
    case .reported(let text): return l10n.format(.automationFailReported, text)
    case .brokeRules: return l10n.string(.automationFormatError)
    case .unreadInput(let count): return l10n.format(.automationFailUnreadInput, count)
    case .noResult: return l10n.string(.automationFailNoResult)
    case .unsourced: return l10n.string(.automationFailUnsourced)
    }
  }

  /// 手段の終わり方。
  func ending(_ ending: AutomationEnding) -> String {
    switch ending {
    case .exited(let code): l10n.format(.automationEndExited, Int(code))
    case .signaled(let signal): l10n.format(.automationEndSignaled, Int(signal))
    case .timeLimit: l10n.string(.automationEndTimeLimit)
    case .idleLimit: l10n.string(.automationEndIdleLimit)
    case .outputLimit: l10n.string(.automationEndOutputLimit)
    case .stopped: l10n.string(.automationEndStopped)
    case .agentMissing(let cli): l10n.format(.automationEndAgentMissing, cli)
    case .directoryMissing(let directory): l10n.format(.automationEndDirectoryMissing, directory)
    case .notStarted: l10n.string(.automationEndNotStarted)
    case .toolsUnavailable(let tools):
      l10n.format(
        .automationEndToolsUnavailable,
        tools.joined(separator: l10n.string(.automationListSeparator)))
    }
  }

  /// 「3 件目：link がありません」（位置の無い誤りは理由だけ）。
  func line(_ broken: AutomationBrokenLine) -> String {
    guard let line = broken.line else { return fault(broken.fault) }
    return l10n.format(.automationLineAt, line, fault(broken.fault))
  }

  /// 外れた件の理由。
  func fault(_ fault: AutomationLineFault) -> String {
    switch fault {
    case .notJSON: l10n.string(.automationFaultNotJSON)
    case .notObject: l10n.string(.automationFaultNotObject)
    case .missingKey(let key): l10n.format(.automationFaultMissing, key)
    case .nullValue(let key): l10n.format(.automationFaultNull, key)
    case .typeMismatch(let key): l10n.format(.automationFaultType, key)
    case .invalidValue(let key) where key.isEmpty: l10n.string(.automationFaultInvalidValue)
    case .invalidValue(let key): l10n.format(.automationFaultInvalid, key)
    case .idTwice(let id): l10n.format(.automationFaultIdTwice, id)
    case .notInputId(let id): l10n.format(.automationFaultNotInputId, id)
    case .notNewItem(let id): l10n.format(.automationFaultNotNewItem, id)
    case .proposedTwice(let id): l10n.format(.automationFaultProposedTwice, id)
    case .notWaiting: l10n.string(.automationFaultNotWaiting)
    case .notOneDecision: l10n.string(.automationFaultNotOneDecision)
    case .titleNotOneLine: l10n.string(.automationFaultTitle)
    case .dueNotDate: l10n.string(.automationFaultDue)
    case .workspaceNotListed: l10n.string(.automationFaultWorkspace)
    case .notArray(let key): l10n.format(.automationFaultNotArray, key)
    case .afterNothing: l10n.string(.automationFaultAfterNothing)
    case .tooLarge: l10n.format(.automationFaultTooLarge, AutomationOutputs.rowKiB)
    }
  }

  /// 判定の確定で捨てた案を理由ごとに数えた添え書き（「候補に登録済みの 2 件を破棄」）。無ければ空。
  func dismissals(_ dismissed: [AutomationDismissal]) -> [String] {
    AutomationDismissal.Why.allCases.compactMap { why in
      let count = dismissed.filter { $0.why == why }.count
      return count > 0 ? l10n.format(Self.key(why), count) : nil
    }
  }

  private static func key(_ why: AutomationDismissal.Why) -> L10nKey {
    switch why {
    case .alreadyProposed: .automationDismissedAlready
    case .noOpenProposal: .automationDismissedNoOpen
    case .originInvalidated: .automationDismissedOriginInvalidated
    }
  }
}
