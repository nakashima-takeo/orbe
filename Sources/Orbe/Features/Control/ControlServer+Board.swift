import Foundation

/// ボードの部品の 3 動詞の domain 操作（`ControlTarget` の一部。main スレッドでのみ呼ぶ）。どれも結果の並び `{parts}` を返す。
/// 知らない workspace は -32004、ボードを持たない workspace は -32000。
protocol ControlBoardTarget: AnyObject {
  /// ボードの部品の並びを読む（list_board_parts）。
  func controlListBoardParts(workspaceId: Int) -> Result<Any, ControlError>
  /// 部品を末尾に置く（add_board_part）。既にあれば何もしない。
  func controlAddBoardPart(workspaceId: Int, part: BoardPart) -> Result<Any, ControlError>
  /// 部品を外す（remove_board_part）。無ければ何もしない。
  func controlRemoveBoardPart(workspaceId: Int, part: BoardPart) -> Result<Any, ControlError>
}

/// ボードの 3 動詞の解決。ハンドラが見るのは params の在否と JSON の型と種類の名前（違反は -32602）だけで、workspace の
/// 解決とボードを持つかは domain 側が決める。
extension ControlServer {
  func boardHandler(for method: String) -> (
    (ControlBoardTarget, [String: Any]) -> Result<Any, ControlError>
  )? {
    guard let body = boardBody(for: method) else { return nil }
    return { target, params in
      do throws(ControlError) {
        return try body(target, BoardParams(params: params))
      } catch {
        return .failure(error)
      }
    }
  }

  private func boardBody(for method: String) -> BoardBody? {
    switch method {
    case "list_board_parts":
      return { target, p throws(ControlError) in
        target.controlListBoardParts(workspaceId: try p.workspaceId())
      }
    case "add_board_part":
      return { target, p throws(ControlError) in
        target.controlAddBoardPart(workspaceId: try p.workspaceId(), part: try p.part())
      }
    case "remove_board_part":
      return { target, p throws(ControlError) in
        target.controlRemoveBoardPart(workspaceId: try p.workspaceId(), part: try p.part())
      }
    default:
      return nil
    }
  }
}

private typealias BoardBody = (ControlBoardTarget, BoardParams) throws(ControlError) -> Result<
  Any, ControlError
>

/// params の型検査。
private struct BoardParams {
  let params: [String: Any]

  /// JSONSerialization は true / false も NSNumber に載せ `as? Int` を通すので、真偽値を整数として受けない。
  func workspaceId() throws(ControlError) -> Int {
    guard let raw = params["workspaceId"] else {
      throw ControlError(code: -32602, message: "missing workspaceId")
    }
    let isBool = (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    guard !isBool, let id = raw as? Int else {
      throw ControlError(code: -32602, message: "invalid workspaceId")
    }
    return id
  }

  func part() throws(ControlError) -> BoardPart {
    guard let raw = params["kind"] else {
      throw ControlError(code: -32602, message: "missing kind")
    }
    guard let kind = raw as? String else {
      throw ControlError(code: -32602, message: "invalid kind")
    }
    guard let part = BoardPart(rawValue: kind) else {
      let known = BoardPart.allCases.map(\.rawValue).joined(separator: ", ")
      throw ControlError(code: -32602, message: "unknown kind: \(kind) (known: \(known))")
    }
    return part
  }
}
