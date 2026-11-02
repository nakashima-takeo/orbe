import Foundation

/// 今の workspace の写し。候補の付け先・コマンドの走る場所・定義の外の形の写しは、どれもこれから引く。
struct AutomationWorkspaces: Equatable {
  /// 今の workspace すべて（Home を含む。サイドバーの順）。
  let all: [AutomationWorkspace]
  /// Home の起動ごとの ID。付け先にこれを書いた行は付け先なし（Home に付く）として受ける——コマンドの判定は
  /// `orb ws list --json` から Home の ID を書きうる。
  let home: Int?

  /// 判定に付け先として見せる workspace（Home を除く）。
  var listed: [AutomationWorkspace] { all.filter { $0.id != home } }

  func workspace(_ persistentId: UUID) -> AutomationWorkspace? {
    all.first { $0.persistentId == persistentId }
  }
}

/// 今の workspace 1 つ。`id` は起動ごとの ID で、外の口でだけ使い保存しない。
struct AutomationWorkspace: Equatable {
  let id: Int
  let persistentId: UUID
  let name: String
  let root: String
}
