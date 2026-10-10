import Foundation
import OrbeSessionLog

/// 取得役と判定の依頼文、その出力の読み取り。入出力の形は Orbe が固定の枠で持つ——利用者の依頼文・指示文が形まで決めると、
/// 受信ごとに形が割れて検証できないため。
enum IntakePrompts {
  // MARK: - 取得

  static func fetch(request: String) -> String {
    """
    You fetch items for Orbe. Use only the tools you were given to fetch what the request below asks for.

    Request:
    \(request)

    Output one JSON object per line and nothing else (no prose, no code fences):
    {"id": "<stable id of the item within this source>", "link": "<http(s) URL of the item>", \
    "body": "<the item's text>", "time": "<ISO 8601 time of the item>"}
    Output nothing when there are no items.
    If a tool fails or is unavailable, output only this one line instead: {"error": "<what went wrong>"}
    """
  }

  enum FetchReading: Equatable {
    case items([IntakeItem], rejected: IntakeRejections)
    case failed(String, rejected: IntakeRejections)
  }

  /// 取得の出力を読む。`{"error":…}` の行（`id` を持たず文字列の `error` を持つ）があるか、1 行以上あって全部が形違いなら
  /// 失敗。同じ id が 2 度出たら後の行を捨てる。
  static func readFetch(_ text: String, truncated: Bool = false) -> FetchReading {
    let lines = JSONLines<IntakeItem>(text, truncated: truncated)
    var rejected = IntakeRejections()
    if let error = JSONLines<FetchError>(text).items.first {
      return .failed("the fetch reported an error: \(error.error)", rejected: rejected)
    }
    for rejection in lines.rejected {
      rejected.add("line \(rejection.line): \(rejection.reason.text)")
    }
    if lines.items.isEmpty, !lines.rejected.isEmpty {
      return .failed("every line of the fetch output was malformed", rejected: rejected)
    }
    var ids = Set<String>()
    var items: [IntakeItem] = []
    for item in lines.items {
      guard ids.insert(item.id).inserted else {
        rejected.add("id \(item.id) appeared twice")
        continue
      }
      items.append(item)
    }
    return .items(items, rejected: rejected)
  }

  // MARK: - 判定

  static func judge(
    instruction: String, items: [IntakeItem], open: [IntakeProposal], now: Date,
    timeZone: TimeZone
  ) -> String {
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.timeZone = timeZone
    local.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
    let itemLines = items.map { jsonLine(IntakeWire.object($0)) }.joined(separator: "\n")
    let openLines = open.map { proposal in
      var entry: [String: Any] = ["link": proposal.item.link, "title": proposal.title]
      if let due = proposal.due { entry["due"] = due.text }
      return jsonLine(entry)
    }.joined(separator: "\n")
    return """
      You decide which incoming items should become tasks on the user's task list. You have no tools; \
      read only what is below.

      Now: \(local.string(from: now)), time zone \(timeZone.identifier).

      The user's instruction:
      \(instruction)

      New items (one JSON object per line):
      \(itemLines)

      Proposals already waiting for the user (one JSON object per line; may be empty):
      \(openLines.isEmpty ? "(none)" : openLines)

      Output one JSON object per line and nothing else (no prose, no code fences):
      - To propose a task for a new item: \
      {"propose": "<item id>", "title": "<one-line task title>", "due": "YYYY-MM-DD"}. \
      Omit due when there is no deadline. At most one proposal per item; use only ids of the new items above.
      - When the new items show that a waiting proposal is already dealt with: {"resolve": "<link of that proposal>"}. \
      Use only links of the waiting proposals above.
      Output nothing when no item needs a task.
      """
  }

  /// 判定の出力を読む。形の違う行・知らない項目や提案を指す行・不正なタイトルや期限・同じ項目への 2 つ目の提案は、
  /// 理由付きで捨てる。
  static func readJudge(_ text: String, items: [IntakeItem], open: [IntakeProposal]) -> (
    decisions: [IntakeDecision], rejected: IntakeRejections
  ) {
    let lines = JSONLines<JudgeLine>(text)
    var rejected = IntakeRejections()
    for rejection in lines.rejected {
      rejected.add("line \(rejection.line): \(rejection.reason.text)")
    }
    let itemIds = Set(items.map(\.id))
    let openLinks = Set(open.map(\.item.link))
    var proposed = Set<String>()
    var resolved = Set<String>()
    var decisions: [IntakeDecision] = []
    for line in lines.items {
      switch (line.propose, line.resolve) {
      case (let id?, nil):
        guard itemIds.contains(id) else {
          rejected.add("propose \(id): not a new item")
          continue
        }
        guard let rawTitle = line.title, let title = try? TaskStore.validTitle(rawTitle) else {
          rejected.add("propose \(id): title must be a single non-empty line")
          continue
        }
        var due: TaskItem.DueDate?
        if let rawDue = line.due {
          guard let parsed = TaskItem.DueDate(rawDue) else {
            rejected.add("propose \(id): due is not a YYYY-MM-DD date: \(rawDue)")
            continue
          }
          due = parsed
        }
        guard proposed.insert(id).inserted else {
          rejected.add("propose \(id): proposed twice")
          continue
        }
        decisions.append(.propose(itemId: id, title: title, due: due))
      case (nil, let link?):
        guard openLinks.contains(link), resolved.insert(link).inserted else {
          rejected.add("resolve \(link): not a waiting proposal")
          continue
        }
        decisions.append(.resolve(link: link))
      default:
        rejected.add("a line must have exactly one of propose / resolve")
      }
    }
    return (decisions, rejected)
  }

  private static func jsonLine(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
      let line = String(data: data, encoding: .utf8)
    else { return "{}" }
    return line
  }
}

/// 取得役の失敗の申告（`id` を持たず文字列の `error` を持つ行）。
private struct FetchError: Decodable {
  let error: String

  private enum CodingKeys: String, CodingKey {
    case id, error
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard !c.contains(.id) else {
      throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "an item")
    }
    error = try c.decode(String.self, forKey: .error)
  }
}

/// 判定の出力 1 行。どちらの形かは `IntakePrompts.readJudge` が決める。
private struct JudgeLine: Decodable {
  let propose: String?
  let resolve: String?
  let title: String?
  let due: String?
}

extension JSONLines.Reason {
  /// 回の記録に残す理由。
  var text: String {
    switch self {
    case .notJSON: "not JSON"
    case .notObject: "not a JSON object"
    case .missingKey(let key): "missing \(key)"
    case .nullValue(let key): "\(key) is null"
    case .typeMismatch(let key): "\(key) has the wrong type"
    case .invalidValue(let key): key.isEmpty ? "invalid value" : "invalid \(key)"
    case .truncated: "cut off by the output limit"
    }
  }
}
