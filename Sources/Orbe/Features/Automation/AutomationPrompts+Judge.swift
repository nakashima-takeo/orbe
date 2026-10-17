import Foundation

extension AutomationPrompts {
  /// タスク候補の出力先が最後の agent の段に渡す依頼文。`rows` は確かめた入力行。
  static func judge(
    instruction: String, rows: [String], choices: AutomationJudgeChoices, now: Date,
    timeZone: TimeZone
  ) -> String {
    judgeFrame(instruction: instruction, rows: rows, choices: choices, now: now, timeZone: timeZone)
      + WhenEmpty.silent.line("no item needs a task")
  }

  /// 部品の 1 回の判定の依頼文。propose も resolve も出さない回は nothing の 1 行を出させる——待っている候補を片付けるだけの
  /// 回も、何も無い回ではない。
  static func partJudge(
    instruction: String, rows: [String], choices: AutomationJudgeChoices, now: Date,
    timeZone: TimeZone
  ) -> String {
    judgeFrame(instruction: instruction, rows: rows, choices: choices, now: now, timeZone: timeZone)
      + WhenEmpty.nothingLine.line("you output no propose or resolve line")
  }

  /// 判定の依頼文の、何も無い回の出し方の前まで（改行で終わる）。
  private static func judgeFrame(
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
      "workspace": <workspace number>}. \
      Omit due when there is no deadline. At most one proposal per item; use only ids of the new items above. \
      Write workspace only when the item clearly belongs to one of the workspaces above (by the user's \
      instruction or by the item itself, such as its repository), using only numbers listed above; omit it \
      when unsure, and the task goes to Home.
      - When the new items show that a waiting proposal is already dealt with: {"resolve": "<link of that proposal>"}. \
      Use only links of the waiting proposals above.

      """
  }

  /// 最後の段の行を判定の出力として読む。propose・resolve の形でない行・知らない項目や候補を指す行・不正なタイトルや
  /// 期限・一覧に無い workspace・同じ項目への 2 つ目の候補は、理由付きで捨てる。Home の workspace は付け先なしとして受ける。
  /// `itemIds` は今回の新しい項目の id。
  static func readJudge(
    _ rows: [AutomationRow], itemIds: Set<String>, choices: AutomationJudgeChoices
  ) -> (decisions: [AutomationDecision], rejected: AutomationRejections) {
    var rejected = AutomationRejections()
    var decisions: [AutomationDecision] = []
    for (row, reading) in judgeRows(rows, itemIds: itemIds, choices: choices) {
      switch reading {
      case .success(let decision): decisions.append(decision)
      case .failure(.malformed(let reason)): rejected.add("line \(row.line): \(reason)")
      case .failure(.refused(let reason)): rejected.add(reason)
      }
    }
    return (decisions, rejected)
  }

  /// 判定の出力の行ごとの読み。受けた決定か、受けられない理由。
  static func judgeRows(
    _ rows: [AutomationRow], itemIds: Set<String>, choices: AutomationJudgeChoices
  ) -> [(row: AutomationRow, reading: Result<AutomationDecision, JudgeRefusal>)] {
    let openLinks = Set(choices.open.map(\.item.link))
    var proposed = Set<String>()
    var resolved = Set<String>()
    return rows.map { row in
      let line: JudgeLine
      switch JSONLines<JudgeLine>.decode(row.text) {
      case .success(let read): line = read
      case .failure(let reason): return (row, .failure(.malformed(reason.text)))
      }
      switch (line.propose, line.resolve) {
      case (let id?, nil):
        let reading = proposal(id, line, itemIds: itemIds, choices: choices)
        if case .success = reading, !proposed.insert(id).inserted {
          return (row, .failure(.refused("propose \(id): proposed twice")))
        }
        return (row, reading)
      case (nil, let link?):
        guard openLinks.contains(link), resolved.insert(link).inserted else {
          return (row, .failure(.refused("resolve \(link): not a waiting proposal")))
        }
        return (row, .success(.resolve(link: link)))
      default:
        return (row, .failure(.refused("a line must have exactly one of propose / resolve")))
      }
    }
  }

  private static func proposal(
    _ id: String, _ line: JudgeLine, itemIds: Set<String>, choices: AutomationJudgeChoices
  ) -> Result<AutomationDecision, JudgeRefusal> {
    guard itemIds.contains(id) else { return .failure(.refused("propose \(id): not a new item")) }
    guard let rawTitle = line.title, let title = try? TaskStore.validTitle(rawTitle) else {
      return .failure(.refused("propose \(id): title must be a single non-empty line"))
    }
    var due: TaskItem.DueDate?
    if let rawDue = line.due {
      guard let parsed = TaskItem.DueDate(rawDue) else {
        return .failure(.refused("propose \(id): due is not a YYYY-MM-DD date: \(rawDue)"))
      }
      due = parsed
    }
    var workspace: UUID?
    if let number = line.workspace, number != choices.workspaces.home {
      guard let listed = choices.workspaces.listed.first(where: { $0.id == number }) else {
        return .failure(.refused("propose \(id): workspace \(number) is not a listed workspace"))
      }
      workspace = listed.persistentId
    }
    return .success(.propose(itemId: id, title: title, due: due, workspace: workspace))
  }

  /// 判定の出力の行を受けられない理由。`malformed` は判定の行として読めない（記録には行番号を添える）、`refused` は読めたが
  /// 受けられない（理由がどの案かを言う）。
  enum JudgeRefusal: Error, Equatable {
    case malformed(String)
    case refused(String)
  }
}

/// 判定の出力 1 行。どちらの形かは `AutomationPrompts.judgeRows` が決める。
private struct JudgeLine: Decodable {
  let propose: String?
  let resolve: String?
  let title: String?
  let due: String?
  let workspace: Int?
}
