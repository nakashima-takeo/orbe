import Foundation

extension AutomationPrompts {
  /// 判定の依頼文。propose も resolve も出さない回は nothing の 1 行を出させる——待っている候補を片付けるだけの回も、何も無い回
  /// ではない。
  static func judge(
    instruction: String, rows: [String], choices: AutomationJudgeChoices, now: Date,
    timeZone: TimeZone
  ) -> String {
    let openLines = choices.open.map { proposal in
      var entry: [String: Any] = ["link": proposal.item.link, "title": proposal.title]
      if let due = proposal.due { entry["due"] = due.text }
      return jsonLine(entry)
    }.joined(separator: "\n")
    let workspaceLines = choices.workspaces.listed.map {
      jsonLine(["workspace": $0.id, "name": $0.name, "root": $0.root] as [String: Any])
    }.joined(separator: "\n")
    return """
      You decide which incoming items should become tasks on the user's task list. You have no tools; \
      read only what is below.

      Now: \(local(now, timeZone)), time zone \(timeZone.identifier).

      The user's instruction:
      \(instruction)

      New items (one JSON object per line):
      \(rows.joined(separator: "\n"))

      Proposals already waiting for the user (one JSON object per line; may be empty):
      \(openLines.isEmpty ? "(none)" : openLines)

      Workspaces the user works in (one JSON object per line; may be empty):
      \(workspaceLines.isEmpty ? "(none)" : workspaceLines)

      Output one JSON object per line and nothing else (no prose, no code fences):
      - To propose a task for a new item: \
      {"propose": "<item id>", "title": "<one-line task title>", "due": "YYYY-MM-DD", \
      "workspace": <workspace number>, "reason": "<why this item should be a task>"}. \
      Write reason in one or two sentences, in the language of the user's instruction. \
      Omit due when there is no deadline. At most one proposal per item; use only ids of the new items above. \
      Write workspace only when the item clearly belongs to one of the workspaces above (by the user's \
      instruction or by the item itself, such as its repository), using only numbers listed above; omit it \
      when unsure, and the task goes to Home.
      - When the new items show that a waiting proposal is already dealt with: {"resolve": "<link of that proposal>"}. \
      Use only links of the waiting proposals above.
      \(whenEmpty("you output no propose or resolve line"))
      """
  }

  /// 判定の出力の行ごとの読み。受けた決定か、受けられない行（行番号と理由）。
  static func judgeRows(
    _ rows: [AutomationRow], itemIds: Set<String>, choices: AutomationJudgeChoices
  ) -> [Result<AutomationDecision, AutomationBrokenLine>] {
    let openLinks = Set(choices.open.map(\.item.link))
    var proposed = Set<String>()
    var resolved = Set<String>()
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
      switch (line.propose, line.resolve) {
      case (let id?, nil):
        let reading = proposal(id, line, itemIds: itemIds, choices: choices, refuse)
        if case .success = reading, !proposed.insert(id).inserted {
          return refuse(.proposedTwice(id))
        }
        return reading
      case (nil, let link?):
        guard openLinks.contains(link), resolved.insert(link).inserted else {
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

/// 判定の出力 1 行。どちらの形かは `AutomationPrompts.judgeRows` が決める。
private struct JudgeLine: Decodable {
  let propose: String?
  let resolve: String?
  let title: String?
  let due: String?
  let workspace: Int?
  let reason: String?
}
