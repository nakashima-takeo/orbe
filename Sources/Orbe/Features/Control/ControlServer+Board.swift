import Foundation

/// ボードのウィジェットの 3 動詞の domain 操作（`ControlTarget` の一部。main スレッドでのみ呼ぶ）。どれも結果の並び `{widgets}` を返す。
/// 知らない workspace は -32004、ボードを持たない workspace は -32000。
protocol ControlBoardTarget: AnyObject {
  /// ボードのウィジェットの並びを読む（list_board_widgets）。
  func controlListBoardWidgets(workspaceId: UUID) -> Result<Any, ControlError>
  /// ウィジェットを末尾に置く（add_board_widget）。既にあれば何もしない。
  func controlAddBoardWidget(workspaceId: UUID, widget: BoardWidget) -> Result<Any, ControlError>
  /// ウィジェットを外す（remove_board_widget）。無ければ何もしない。
  func controlRemoveBoardWidget(workspaceId: UUID, widget: BoardWidget) -> Result<Any, ControlError>
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
    case "list_board_widgets":
      return { target, p throws(ControlError) in
        target.controlListBoardWidgets(workspaceId: try ControlWorkspaceId.required(p.params))
      }
    case "add_board_widget":
      return { target, p throws(ControlError) in
        target.controlAddBoardWidget(
          workspaceId: try ControlWorkspaceId.required(p.params), widget: try p.widget())
      }
    case "remove_board_widget":
      return { target, p throws(ControlError) in
        target.controlRemoveBoardWidget(
          workspaceId: try ControlWorkspaceId.required(p.params), widget: try p.widget())
      }
    default:
      return nil
    }
  }
}

private typealias BoardBody = (ControlBoardTarget, BoardParams) throws(ControlError) -> Result<
  Any, ControlError
>

/// params の型検査（workspace の ID は `ControlWorkspaceId`）。
private struct BoardParams {
  let params: [String: Any]

  func widget() throws(ControlError) -> BoardWidget {
    guard let raw = params["kind"] else {
      throw ControlError(code: -32602, message: "missing kind")
    }
    guard let kind = raw as? String else {
      throw ControlError(code: -32602, message: "invalid kind")
    }
    guard let widget = BoardWidget(rawValue: kind) else {
      let known = BoardWidget.allCases.map(\.rawValue).joined(separator: ", ")
      throw ControlError(code: -32602, message: "unknown kind: \(kind) (known: \(known))")
    }
    return widget
  }
}
