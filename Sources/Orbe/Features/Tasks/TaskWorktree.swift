import Foundation

/// タスクの worktree。値は根（`GitWorktreeRoot.root(of:)`）で、タブの連のキーと同じ規則で揃って
/// いるので、「その worktree のタブ」はキーの等値だけで決まる。等値は中のパスの文字列。
/// 永続とワイヤの形はパスの文字列。
struct TaskWorktree: Hashable, Codable {
  let path: String

  /// パスから作る唯一の入口。実在するディレクトリの絶対パスだけを受け、それを含む worktree のルート
  /// （git の外ならそのディレクトリ）に揃える。worktree の中のサブディレクトリを渡してもルートになる。
  /// 揃えた値が読み込みの形（`isWellFormed`）に合わなければ受けない——書いた値を次の読み込みが拒むと、
  /// tasks.json が丸ごと退避される。
  init?(directory: String) {
    var isDirectory: ObjCBool = false
    guard directory.hasPrefix("/"),
      FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    let key = GitWorktreeRoot.root(of: directory)
    guard Self.isWellFormed(key) else { return nil }
    path = key
  }

  /// 保存した値を読む。ファイルシステムには触らず、形（`isWellFormed`）だけを確かめる——消えた worktree の
  /// 値も読める。
  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard Self.isWellFormed(raw) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "not a worktree path: \(raw)"))
    }
    path = raw
  }

  /// 値の形。空でない絶対パスで、制御文字（Cc）と改行類（U+2028 / U+2029 を含む）を含まない（タイトルと
  /// 同じ規則。保存とワイヤの 1 行を壊さない）。書き込みと読み込みが同じこの規則を当てる。
  static func isWellFormed(_ path: String) -> Bool {
    path.hasPrefix("/")
      && !path.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
      })
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(path)
  }

  /// 今もディレクトリとして在るか。無い worktree は、読む側が「なし」と同じに扱う。
  var exists: Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

extension TaskItem {
  /// このタスクの worktree で動いている agent（`agents` は `WorktreeAgentActivity` の索引。状態は問わない）。
  /// 完了したタスクには出さない（今の作業が、別の作業を誤って示す）。
  func agent(in agents: [String: WorktreeAgentActivity.Agent]) -> WorktreeAgentActivity.Agent? {
    status == .done ? nil : worktree.flatMap { agents[$0.path] }
  }
}

#if DEBUG
  extension TaskWorktree {
    /// 既に場所のキーであるパスをそのまま持つ（テストと見本の固定値用。ファイルシステムに触らない）。
    init(key: String) { path = key }
  }
#endif
