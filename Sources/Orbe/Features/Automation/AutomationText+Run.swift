import Foundation

/// 回の失敗と外れた行の、画面の言い方。種類から日本語の説明を引き、AI が読む英文（原文）を括弧で添える。Orbe が種類を決め
/// られない文（部品の申告・CLI のエラー）は、説明の頭の後に文をそのまま添え、原文を重ねない。
extension AutomationText {
  /// 「制限時間内に終わらなかった（the part "x" ended: stopped at the time limit）」。
  func failure(_ run: AutomationPartRun, node: AutomationGraph.Node) -> String? {
    guard let failure = run.failure else { return nil }
    let head = failureHead(failure, ending: run.execution.ending, node: node)
    switch failure {
    case .agentError, .reported: return head
    default:
      let original = failure.text(part: node.key, ending: run.execution.ending, breach: run.breach)
      return l10n.format(.automationWithOriginal, head, original)
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
      if case .agent(let agent) = node.part.method { cli = agent.cli }
      return l10n.format(.automationFailAgentError, cli, text)
    case .reported(let text): return l10n.format(.automationFailReported, text)
    case .brokeRules: return l10n.string(.automationFailBrokeRules)
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
    case .stopped, .heldByTrial, .givenToTrial: l10n.string(.automationEndStopped)
    case .agentMissing(let cli): l10n.format(.automationEndAgentMissing, cli)
    case .directoryMissing(let directory): l10n.format(.automationEndDirectoryMissing, directory)
    case .notStarted: l10n.string(.automationEndNotStarted)
    case .toolsUnavailable(let tools):
      l10n.format(
        .automationEndToolsUnavailable,
        tools.joined(separator: l10n.string(.automationListSeparator)))
    }
  }

  /// 「3 行目：link が無い」。
  func line(_ broken: AutomationBrokenLine) -> String {
    l10n.format(.automationLineAt, broken.line, fault(broken.fault))
  }

  /// 外れた行の理由。
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
    case .nothingWithItems: l10n.string(.automationFaultNothingWithItems)
    case .notNewItem(let id): l10n.format(.automationFaultNotNewItem, id)
    case .proposedTwice(let id): l10n.format(.automationFaultProposedTwice, id)
    case .notWaiting: l10n.string(.automationFaultNotWaiting)
    case .notOneDecision: l10n.string(.automationFaultNotOneDecision)
    case .titleNotOneLine: l10n.string(.automationFaultTitle)
    case .dueNotDate: l10n.string(.automationFaultDue)
    case .workspaceNotListed: l10n.string(.automationFaultWorkspace)
    }
  }

  /// 判定の確定で捨てた案を理由ごとに数えた添え書き（「既に候補にあるので 2 件を捨てた」）。無ければ空。
  func dismissals(_ dismissed: [AutomationDismissal]) -> [String] {
    let already = dismissed.filter { $0.why == .alreadyProposed }.count
    let noOpen = dismissed.count - already
    return (already > 0 ? [l10n.format(.automationDismissedAlready, already)] : [])
      + (noOpen > 0 ? [l10n.format(.automationDismissedNoOpen, noOpen)] : [])
  }
}
