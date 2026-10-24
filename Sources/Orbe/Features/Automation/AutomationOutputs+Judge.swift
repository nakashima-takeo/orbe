import Foundation

extension AutomationOutputs {
  /// 判定の結果の 1 件の形。コマンドの行は `{"propose": <id>, …}` か `{"resolve": <リンク>}`、agent の `propose` の 1 件は
  /// `{"id": <id>, …}`（どれも案）。
  enum JudgeShape {
    case decisions
    case proposals
  }

  /// この回でもう受けた案の id と、対応済みにするリンク。
  struct JudgeSeen {
    var proposed = Set<String>()
    var resolved = Set<String>()
  }

  /// 判定の結果の 1 件ずつの読み。受けた決定か、受けられない件（位置と理由）。`seen` に受けた分を足す。
  static func judgeRows(
    _ rows: [AutomationRow], _ shape: JudgeShape, itemIds: Set<String>,
    choices: AutomationJudgeChoices, seen: inout JudgeSeen
  ) -> [Result<AutomationDecision, AutomationBrokenLine>] {
    let openLinks = Set(choices.open.map(\.item.link))
    return rows.map { row in
      let refuse = { (fault: AutomationLineFault) in
        Result<AutomationDecision, AutomationBrokenLine>.failure(
          AutomationBrokenLine(line: row.line, fault: fault))
      }
      let line: JudgeLine
      switch JSONLines<JudgeLine>.decode(row.text) {
      case .success(let read): line = read
      case .failure(let reason): return refuse(AutomationLineFault(reason))
      }
      func propose(_ id: String) -> Result<AutomationDecision, AutomationBrokenLine> {
        let reading = proposal(id, line, itemIds: itemIds, choices: choices, refuse)
        if case .success = reading, !seen.proposed.insert(id).inserted {
          return refuse(.proposedTwice(id))
        }
        return reading
      }
      if shape == .proposals {
        guard let id = line.id else { return refuse(.missingKey("id")) }
        return propose(id)
      }
      switch (line.propose, line.resolve) {
      case (let id?, nil):
        return propose(id)
      case (nil, let link?):
        guard openLinks.contains(link), seen.resolved.insert(link).inserted else {
          return refuse(.notWaiting(link))
        }
        return .success(.resolve(link: link))
      default:
        return refuse(.notOneDecision)
      }
    }
  }

  private static func proposal(
    _ id: String, _ line: JudgeLine, itemIds: Set<String>, choices: AutomationJudgeChoices,
    _ refuse: (AutomationLineFault) -> Result<AutomationDecision, AutomationBrokenLine>
  ) -> Result<AutomationDecision, AutomationBrokenLine> {
    guard itemIds.contains(id) else { return refuse(.notNewItem(id)) }
    guard let rawTitle = line.title, let title = try? TaskStore.validTitle(rawTitle) else {
      return refuse(.titleNotOneLine(id))
    }
    var due: TaskItem.DueDate?
    if let rawDue = line.due {
      guard let parsed = TaskItem.DueDate(rawDue) else { return refuse(.dueNotDate(id, rawDue)) }
      due = parsed
    }
    var workspace: UUID?
    if let number = line.workspace, number != choices.workspaces.home {
      guard let listed = choices.workspaces.listed.first(where: { $0.id == number }) else {
        return refuse(.workspaceNotListed(id, number))
      }
      workspace = listed.persistentId
    }
    return .success(
      .propose(
        itemId: id, title: title, due: due, workspace: workspace, reason: reason(line.reason)))
  }

  /// 候補にした理由を 1 段落に整える（行の区切りと連なる空白を 1 つの空白に）。空なら無い。
  private static func reason(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return text.isEmpty ? nil : text
  }
}

/// 判定の結果 1 件。どちらの形かは `AutomationOutputs.judgeRows` が決める。
private struct JudgeLine: Decodable {
  /// agent の `propose` の 1 件の案の id。
  let id: String?
  let propose: String?
  let resolve: String?
  let title: String?
  let due: String?
  let workspace: Int?
  let reason: String?
}
