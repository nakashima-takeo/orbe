import Foundation
import OrbeSessionLog

/// 回の記録の外の形（`list_automations` の `lastRun`・`list_automation_runs` の `runs`・部品の `breach`・試走の部品の回）。保存の
/// 形（種類だけ）に、AI が読む英文を足す——終わり方の `ending`・失敗の `failure`・外れた件の `reasons`・判定の確定で捨てた案の
/// `rejected`。英文は部品の鍵が要るので、鍵を手元に持つここで組む。
enum AutomationRunWire {
  /// 記録 1 件（`recordId` を添える）。不明な記録は列から分かる分と `unknown: true` だけ。
  static func object(_ record: AutomationRunRecord, part: String) -> [String: Any] {
    switch record.content {
    case .known(let run):
      var json = object(run, part: part)
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

  static func object(_ run: AutomationNodeRun, part: String) -> [String: Any] {
    var json = AutomationWire.object(run) as? [String: Any] ?? [:]
    json["execution"] = execution(json["execution"], run.execution)
    if let failure = run.failure {
      json["failure"] = failure.text(part: part, ending: run.execution.ending, breach: run.breach)
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

  /// 部品の外した印（印の回の記録から）: その回の開始時刻・外れた件・回が通ったか。読めない記録の外れた件は空。
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
