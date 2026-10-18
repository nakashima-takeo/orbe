import Foundation

/// 回の記録の外の形（`list_automations` の `runs`・部品の `breach`・試走の部品の回）。保存の形（種類だけ）に、AI が読む英文を
/// 足す——終わり方の `ending`・失敗の `failure`・外れた行の `reasons`・判定の確定で捨てた案の `rejected`。英文は部品の鍵が要るので、
/// 鍵を手元に持つここで組む。
enum AutomationRunWire {
  static func object(_ run: AutomationPartRun, part: String) -> [String: Any] {
    var json = AutomationWire.object(run) as? [String: Any] ?? [:]
    json["execution"] = execution(json["execution"], run.execution)
    if let failure = run.failure {
      json["failure"] = failure.text(part: part, ending: run.execution.ending, breach: run.breach)
    }
    if let breach = run.breach, var object = json["breach"] as? [String: Any] {
      object["lines"] = rejections(object["lines"], breach.lines)
      if let redo = breach.redo, var redoObject = object["redo"] as? [String: Any] {
        redoObject["firstCall"] = execution(redoObject["firstCall"], redo.firstCall)
        if redo.lines.count > 0 {
          redoObject["lines"] = rejections(redoObject["lines"], redo.lines)
        }
        object["redo"] = redoObject
      }
      json["breach"] = object
    }
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

  static func objects(_ runs: [AutomationPartRun], part: String) -> [[String: Any]] {
    runs.map { object($0, part: part) }
  }

  /// 部品の外した印。
  static func object(_ mark: AutomationBreachMark) -> [String: Any] {
    var json = AutomationWire.object(mark) as? [String: Any] ?? [:]
    json["lines"] = rejections(json["lines"], mark.lines)
    return json
  }

  private static func execution(
    _ object: Any?, _ execution: AutomationPartPass.Execution
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
