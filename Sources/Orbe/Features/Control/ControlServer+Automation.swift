import Foundation

/// 自動化の 6 動詞の domain 操作（`ControlTarget` の一部。main スレッドでのみ呼ぶ）。
protocol ControlAutomationTarget: AnyObject {
  /// 自動化を ID 順に列挙する（list_automations）。
  func controlListAutomations() -> Result<Any, ControlError>
  /// 自動化を作るか丸ごと置き換える（set_automation）。automationId が nil なら作る。未知の automationId は -32004。
  func controlSetAutomation(automationId: Int?, _ definition: AutomationDefinition) -> Result<
    Any, ControlError
  >
  /// 今すぐ回す（run_automation）。走っている回があれば -32000。
  func controlRunAutomation(automationId: Int) -> Result<Any, ControlError>
  /// 予定を止める・再開する（pause_automation）。
  func controlPauseAutomation(automationId: Int, paused: Bool) -> Result<Any, ControlError>
  /// 消す（delete_automation）。
  func controlDeleteAutomation(automationId: Int) -> Result<Any, ControlError>
  /// 覚えている提案を列挙する（list_automation_proposals）。automationId 指定はその自動化の棚の分。
  func controlListAutomationProposals(automationId: Int?) -> Result<Any, ControlError>
}

/// 自動化の 6 動詞の解決。ハンドラが見るのは params の在否と JSON の型（違反は -32602）だけで、値の検証と不変条件は
/// `AutomationStore` が持つ。
extension ControlServer {
  func automationHandler(for method: String) -> (
    (ControlAutomationTarget, [String: Any]) -> Result<Any, ControlError>
  )? {
    guard let body = automationBody(for: method) else { return nil }
    return { target, params in
      do throws(ControlError) {
        return try body(target, AutomationParams(params))
      } catch {
        return .failure(error)
      }
    }
  }

  private func automationBody(for method: String) -> AutomationBody? {
    switch method {
    case "list_automations":
      return { target, _ throws(ControlError) in target.controlListAutomations() }
    case "set_automation":
      return { target, p throws(ControlError) in
        target.controlSetAutomation(
          automationId: try p.optionalInt("automationId"), try p.definition())
      }
    case "run_automation":
      return { target, p throws(ControlError) in
        target.controlRunAutomation(automationId: try p.int("automationId"))
      }
    case "pause_automation":
      return { target, p throws(ControlError) in
        target.controlPauseAutomation(
          automationId: try p.int("automationId"), paused: try p.bool("paused"))
      }
    case "delete_automation":
      return { target, p throws(ControlError) in
        target.controlDeleteAutomation(automationId: try p.int("automationId"))
      }
    case "list_automation_proposals":
      return { target, p throws(ControlError) in
        target.controlListAutomationProposals(automationId: try p.optionalInt("automationId"))
      }
    default:
      return nil
    }
  }
}

private typealias AutomationBody = (ControlAutomationTarget, AutomationParams) throws(ControlError)
  -> Result<
    Any, ControlError
  >

/// params の型検査。定義は `definition` の欄を保存と同じ形（`AutomationDefinition`）で読み、読めない箇所を -32602 の文に入れる。
private struct AutomationParams {
  let params: [String: Any]

  init(_ params: [String: Any]) { self.params = params }

  private static func isBool(_ raw: Any) -> Bool {
    (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
  }

  func int(_ key: String) throws(ControlError) -> Int {
    guard let value = try optionalInt(key) else {
      throw ControlError(code: -32602, message: "missing \(key)")
    }
    return value
  }

  /// JSONSerialization は true / false も NSNumber に載せ `as? Int` を通すので、真偽値を整数として受けない。
  func optionalInt(_ key: String) throws(ControlError) -> Int? {
    guard let raw = params[key] else { return nil }
    guard !Self.isBool(raw), let value = raw as? Int else {
      throw ControlError(code: -32602, message: "invalid \(key)")
    }
    return value
  }

  func bool(_ key: String) throws(ControlError) -> Bool {
    guard let raw = params[key] else { throw ControlError(code: -32602, message: "missing \(key)") }
    guard Self.isBool(raw), let value = raw as? Bool else {
      throw ControlError(code: -32602, message: "invalid \(key)")
    }
    return value
  }

  func definition() throws(ControlError) -> AutomationDefinition {
    guard let raw = params["definition"] else {
      throw ControlError(code: -32602, message: "missing definition")
    }
    guard raw is [String: Any] else {
      throw ControlError(code: -32602, message: "invalid definition")
    }
    do {
      let data = try JSONSerialization.data(withJSONObject: raw)
      return try AutomationWire.decoder.decode(AutomationDefinition.self, from: data)
    } catch DecodingError.keyNotFound(let key, let context) {
      throw ControlError(code: -32602, message: "missing \(path(context.codingPath + [key]))")
    } catch DecodingError.typeMismatch(_, let context) {
      throw ControlError(code: -32602, message: "invalid \(path(context.codingPath))")
    } catch DecodingError.valueNotFound(_, let context) {
      throw ControlError(code: -32602, message: "invalid \(path(context.codingPath))")
    } catch DecodingError.dataCorrupted(let context) {
      let at = path(context.codingPath)
      throw ControlError(
        code: -32602,
        message: at.isEmpty
          ? context.debugDescription : "invalid \(at): \(context.debugDescription)")
    } catch {
      throw ControlError(code: -32602, message: "invalid params")
    }
  }

  /// `steps[0].instruction` の形（`definition` の中の場所）。
  private func path(_ keys: [CodingKey]) -> String {
    keys.reduce(into: "") { path, key in
      if let index = key.intValue {
        path += "[\(index)]"
      } else {
        path += path.isEmpty ? key.stringValue : "." + key.stringValue
      }
    }
  }
}
