import Foundation

/// ボードの部品の 3 動詞の domain 側。並びの意味（ボードを持つか・既定・置ける／外せるか）は `SessionStore` が決め、ここは
/// workspace を引き、変わったら保存を予約して前面のボードへ写し、結果の並びを返す。人の選択・焦点・前面の workspace は動かさない。
extension WindowController {
  func controlListBoardParts(workspaceId: Int) -> Result<Any, ControlError> {
    boardResult(workspaceId) { _ throws(SessionStore.NoBoard) in }
  }

  func controlAddBoardPart(workspaceId: Int, part: BoardPart) -> Result<Any, ControlError> {
    boardResult(workspaceId) { ws throws(SessionStore.NoBoard) in
      if try store.addBoardPart(part, to: ws) { boardPartsChanged(in: ws) }
    }
  }

  func controlRemoveBoardPart(workspaceId: Int, part: BoardPart) -> Result<Any, ControlError> {
    boardResult(workspaceId) { ws throws(SessionStore.NoBoard) in
      if try store.removeBoardPart(part, from: ws) { boardPartsChanged(in: ws) }
    }
  }

  private func boardPartsChanged(in ws: Workspace) {
    if ws === current { projectBoardParts() }
    scheduleSave()
  }

  private func boardResult(
    _ workspaceId: Int, _ body: (Workspace) throws(SessionStore.NoBoard) -> Void
  ) -> Result<Any, ControlError> {
    guard let ws = workspaces.first(where: { $0.id == workspaceId }) else {
      return .failure(ControlError(code: -32004, message: "workspace not found"))
    }
    let noBoard = ControlError(code: -32000, message: "workspace has no board")
    do throws(SessionStore.NoBoard) {
      try body(ws)
    } catch {
      return .failure(noBoard)
    }
    guard let parts = store.boardParts(of: ws) else { return .failure(noBoard) }
    return .success(["parts": parts.map(\.json)])
  }
}
