import Foundation

/// ボードのウィジェットの並びの意味——ボードを持つか（`hasBoard`）・既定・置ける／外せるか。「1 種類 1 つ」の保証者は
/// ここと `load` の正規化だけ。
extension SessionStore {
  /// 何も決めていないボードのウィジェットの並び。
  static let defaultBoardWidgets: [BoardWidget] = [.automation]

  /// ボードを持たない workspace へウィジェットを置こうとした・外そうとした。
  struct NoBoard: Error {}

  /// その workspace のボードのウィジェットの並び。ボードを持たなければ nil。
  func boardWidgets(of ws: Workspace) -> [BoardWidget]? {
    guard hasBoard(ws) else { return nil }
    return ws.boardWidgets ?? Self.defaultBoardWidgets
  }

  /// ウィジェットを末尾に置き、変わったかを返す。既にあれば何もしない。
  func addBoardWidget(_ widget: BoardWidget, to ws: Workspace) throws(NoBoard) -> Bool {
    guard let widgets = boardWidgets(of: ws) else { throw NoBoard() }
    guard !widgets.contains(widget) else { return false }
    ws.boardWidgets = widgets + [widget]
    return true
  }

  /// ウィジェットを外し、変わったかを返す。無ければ何もしない。外して空になった並びも「決めた並び」として残す。
  func removeBoardWidget(_ widget: BoardWidget, from ws: Workspace) throws(NoBoard) -> Bool {
    guard let widgets = boardWidgets(of: ws) else { throw NoBoard() }
    guard widgets.contains(widget) else { return false }
    ws.boardWidgets = widgets.filter { $0 != widget }
    return true
  }

  /// 同じ種類の重なりを落とす（先を残す）。`load` の正規化が使う。
  static func distinct(_ widgets: [BoardWidget]) -> [BoardWidget] {
    var seen = Set<BoardWidget>()
    return widgets.filter { seen.insert($0).inserted }
  }
}
