import Foundation

extension AutomationPrompts {
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
