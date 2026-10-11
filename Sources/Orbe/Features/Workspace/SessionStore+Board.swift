import Foundation

/// ボードの部品の並びの意味——ボードを持つか（`hasBoard`）・既定・置ける／外せるか。「1 種類 1 つ」の保証者は
/// ここと `load` の正規化だけ。
extension SessionStore {
  /// 何も決めていないボードの部品の並び。
  static let defaultBoardParts: [BoardPart] = [.intake]

  /// ボードを持たない workspace へ部品を置こうとした・外そうとした。
  struct NoBoard: Error {}

  /// その workspace のボードの部品の並び。ボードを持たなければ nil。
  func boardParts(of ws: Workspace) -> [BoardPart]? {
    guard hasBoard(ws) else { return nil }
    return ws.boardParts ?? Self.defaultBoardParts
  }

  /// 部品を末尾に置き、変わったかを返す。既にあれば何もしない。
  func addBoardPart(_ part: BoardPart, to ws: Workspace) throws(NoBoard) -> Bool {
    guard let parts = boardParts(of: ws) else { throw NoBoard() }
    guard !parts.contains(part) else { return false }
    ws.boardParts = parts + [part]
    return true
  }

  /// 部品を外し、変わったかを返す。無ければ何もしない。外して空になった並びも「決めた並び」として残す。
  func removeBoardPart(_ part: BoardPart, from ws: Workspace) throws(NoBoard) -> Bool {
    guard let parts = boardParts(of: ws) else { throw NoBoard() }
    guard parts.contains(part) else { return false }
    ws.boardParts = parts.filter { $0 != part }
    return true
  }

  /// 同じ種類の重なりを落とす（先を残す）。`load` の正規化が使う。
  static func distinct(_ parts: [BoardPart]) -> [BoardPart] {
    var seen = Set<BoardPart>()
    return parts.filter { seen.insert($0).inserted }
  }
}
