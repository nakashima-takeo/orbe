import Foundation

/// 受信の 6 動詞の domain 操作（`ControlTarget` の一部。main スレッドでのみ呼ぶ）。
protocol ControlIntakeTarget: AnyObject {
  /// 受信を ID 順に列挙する（list_intakes）。
  func controlListIntakes() -> Result<Any, ControlError>
  /// 受信を作るか丸ごと置き換える（set_intake）。intakeId が nil なら作る。未知の intakeId は -32004。
  func controlSetIntake(intakeId: Int?, _ definition: IntakeDefinition) -> Result<Any, ControlError>
  /// 今すぐ回す（run_intake）。走っている回があれば -32000。
  func controlRunIntake(intakeId: Int) -> Result<Any, ControlError>
  /// 予定を止める・再開する（pause_intake）。
  func controlPauseIntake(intakeId: Int, paused: Bool) -> Result<Any, ControlError>
  /// 消す（delete_intake）。
  func controlDeleteIntake(intakeId: Int) -> Result<Any, ControlError>
  /// 覚えている提案を列挙する（list_intake_proposals）。intakeId 指定はその受信の棚の分。
  func controlListIntakeProposals(intakeId: Int?) -> Result<Any, ControlError>
}

/// 受信の 6 動詞の解決。ハンドラが見るのは params の在否と JSON の型（違反は -32602）だけで、値の検証と不変条件は
/// `IntakeStore` が持つ。
extension ControlServer {
  func intakeHandler(for method: String) -> (
    (ControlIntakeTarget, [String: Any]) -> Result<Any, ControlError>
  )? {
    guard let body = intakeBody(for: method) else { return nil }
    return { target, params in
      do throws(ControlError) {
        return try body(target, IntakeParams(params))
      } catch {
        return .failure(error)
      }
    }
  }

  private func intakeBody(for method: String) -> IntakeBody? {
    switch method {
    case "list_intakes":
      return { target, _ throws(ControlError) in target.controlListIntakes() }
    case "set_intake":
      return { target, p throws(ControlError) in
        target.controlSetIntake(intakeId: try p.optionalInt("intakeId"), try p.definition())
      }
    case "run_intake":
      return { target, p throws(ControlError) in
        target.controlRunIntake(intakeId: try p.int("intakeId"))
      }
    case "pause_intake":
      return { target, p throws(ControlError) in
        target.controlPauseIntake(intakeId: try p.int("intakeId"), paused: try p.bool("paused"))
      }
    case "delete_intake":
      return { target, p throws(ControlError) in
        target.controlDeleteIntake(intakeId: try p.int("intakeId"))
      }
    case "list_intake_proposals":
      return { target, p throws(ControlError) in
        target.controlListIntakeProposals(intakeId: try p.optionalInt("intakeId"))
      }
    default:
      return nil
    }
  }
}

private typealias IntakeBody = (ControlIntakeTarget, IntakeParams) throws(ControlError) -> Result<
  Any, ControlError
>

/// params の型検査。定義は intakes.json と同じ `Decodable` で読み、読めない箇所を -32602 の文に入れる。
private struct IntakeParams {
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

  func definition() throws(ControlError) -> IntakeDefinition {
    do {
      let data = try JSONSerialization.data(withJSONObject: params)
      return try IntakeWire.decoder.decode(IntakeDefinition.self, from: data)
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

  /// `fetch.tools[0]` の形。
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
