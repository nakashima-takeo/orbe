import Foundation

/// 今の workspace の写し。候補の付け先・コマンドの走る場所・定義の席の確かめは、どれもこれから引く。
struct AutomationWorkspaces: Equatable {
  /// 今の workspace すべて（Home を含む。サイドバーの順）。
  let all: [AutomationWorkspace]
  /// Home の ID。付け先にこれを書いた行は付け先なし（Home に付く）として受ける——コマンドの判定は
  /// `orb ws list --json` から Home の ID を書きうる。
  let home: UUID?

  /// 判定に付け先として見せる workspace（Home を除く）。
  var listed: [AutomationWorkspace] { all.filter { $0.id != home } }

  func workspace(_ id: UUID) -> AutomationWorkspace? {
    all.first { $0.id == id }
  }
}

/// 今の workspace 1 つ。`id` は `Workspace.id`。
struct AutomationWorkspace: Equatable {
  let id: UUID
  let name: String
  let root: String
}
