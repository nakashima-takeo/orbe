@testable import Orbe

extension WindowController {
  /// 通常の workspace（起動時に末尾へ足される Home を除く）。復元した構成を位置で指すテストが読む。
  var regularWorkspaces: [Workspace] {
    workspaces.indices.filter { !store.isHome($0) }.map { workspaces[$0] }
  }
}
