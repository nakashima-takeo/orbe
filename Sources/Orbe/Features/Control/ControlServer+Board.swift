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

/// ボードの 3 動詞。ハンドラが見るのは引数の在否と JSON の型と種類の名前（違反は -32602）だけで、workspace の解決とボードを
/// 持つかは domain 側が決める。
extension ControlServer {
  static func listBoardWidgets(_ target: ControlBoardTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    target.controlListBoardWidgets(workspaceId: try p.workspaceId())
  }

  static func addBoardWidget(_ target: ControlBoardTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    let workspaceId = try p.workspaceId()
    return target.controlAddBoardWidget(workspaceId: workspaceId, widget: try p.widget())
  }

  static func removeBoardWidget(_ target: ControlBoardTarget, _ p: ControlParams)
    throws(ControlError) -> Result<Any, ControlError>
  {
    let workspaceId = try p.workspaceId()
    return target.controlRemoveBoardWidget(workspaceId: workspaceId, widget: try p.widget())
  }
}

extension ControlParams {
  fileprivate func widget() throws(ControlError) -> BoardWidget {
    let kind = try string("kind")
    guard let widget = BoardWidget(rawValue: kind) else {
      let known = BoardWidget.allCases.map(\.rawValue).joined(separator: ", ")
      throw ControlError(code: -32602, message: "unknown kind: \(kind) (known: \(known))")
    }
    return widget
  }
}
