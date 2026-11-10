import Foundation
import OrbeSessionLog

/// 回の記録の外の形（`list_automations` の `lastRun`・`list_automation_runs` の `runs`・ノードの `breach`・試走のノードの回）。保存の
/// 形（種類だけ）に、AI が読む英文と、報告と仕事のノードが書いた文の 1 行目（`summary`）を足す——英文は終わり方の `ending`・失敗の `failure`・
/// 外れた件の `reasons`・判定の確定で捨てた案の `rejected`。英文はノードの鍵が要るので、鍵を手元に持つこの enum で組む。
enum AutomationRunWire {
  /// 記録 1 件（`recordId` を添える）。不明な記録は列から分かる分と `unknown: true` だけ。
  static func object(_ record: AutomationRunRecord, nodeKey: String) -> [String: Any] {
    switch record.content {
    case .known(let run):
      var json = object(run, nodeKey: nodeKey)
      json["recordId"] = record.id
      return json
    case .unknown(let run):
      return [
        "recordId": record.id, "startedAt": SessionEvent.iso8601(run.startedAt),
        "endedAt": SessionEvent.iso8601(run.endedAt), "trigger": run.trigger.rawValue,
        "failed": run.failed, "unknown": true,
      ]
    }
  }

  /// 一覧（`list_automations` の `lastRun`）の形: 記録 1 件から、報告と仕事のノードが書いた文の全文 `text` を除いたもの。一覧は状態を見る API なので、
  /// 報告のノードが多い自動化でも全文で膨らませない（全文は `list_automation_runs`）。
  static func listed(_ record: AutomationRunRecord, nodeKey: String) -> [String: Any] {
    var json = object(record, nodeKey: nodeKey)
    if var result = json["result"] as? [String: Any] {
      result["text"] = nil
      json["result"] = result
    }
    return json
  }

  static func object(_ run: AutomationNodeRun, nodeKey: String) -> [String: Any] {
    var json = AutomationWire.object(run) as? [String: Any] ?? [:]
    if let summary = run.result?.summary, var result = json["result"] as? [String: Any] {
      result["summary"] = summary
      json["result"] = result
    }
    json["execution"] = execution(json["execution"], run.execution)
    if let failure = run.failure {
      json["failure"] = failure.text(
        nodeKey: nodeKey, ending: run.execution.ending, breach: run.breach)
    }
    if let breach = run.breach { json["breach"] = rejections(json["breach"], breach) }
    if case .judge(_, _, let dismissed) = run.result, !dismissed.isEmpty,
      var result = json["result"] as? [String: Any]
    {
      result["rejected"] =
        [
          "count": dismissed.count,
          "reasons": dismissed.prefix(AutomationRejections.retainedLines).map(\.text),
        ] as [String: Any]
      json["result"] = result
    }
    return json
  }

  /// ノードの外した印（印の回の記録から）: その回の開始時刻・外れた件・回が通ったか。読めない記録の外れた件は空。
  static func breach(_ record: AutomationRunRecord) -> [String: Any] {
    let lines = record.run?.breach ?? AutomationRejections()
    return [
      "at": SessionEvent.iso8601(record.startedAt),
      "lines": rejections(AutomationWire.object(lines), lines), "passed": !record.failed,
    ]
  }

  private static func execution(
    _ object: Any?, _ execution: AutomationNodePass.Execution
  ) -> [String: Any] {
    var json = object as? [String: Any] ?? [:]
    json["ending"] = execution.ending.text
    return json
  }

  private static func rejections(_ object: Any?, _ rejections: AutomationRejections) -> [String:
    Any]
  {
    var json = object as? [String: Any] ?? [:]
    json["reasons"] = rejections.lines.map(\.text)
    return json
  }
}
