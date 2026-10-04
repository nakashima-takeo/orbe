import Foundation

/// タスクの worktree。値は場所のキー（`GitWorktreeRoot.locationKey`）で、タブの連のキーと同じ規則で揃って
/// いるので、「その worktree のタブ」はキーの等値だけで決まる。等値は中のパスの文字列。
/// 永続とワイヤの形はパスの文字列。
struct TaskWorktree: Hashable, Codable {
  let path: String

  /// パスから作る唯一の入口。実在するディレクトリの絶対パスだけを受け、それを含む worktree のルート
  /// （git の外ならそのディレクトリ）に揃える。worktree の中のサブディレクトリを渡してもルートになる。
  init?(directory: String) {
    var isDirectory: ObjCBool = false
    guard directory.hasPrefix("/"),
      FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    path = GitWorktreeRoot.locationKey(of: directory)
  }

  /// 保存した値を読む。ファイルシステムには触らず、形（空でない絶対パスで、制御文字・改行類を含まない）
  /// だけを確かめる——消えた worktree の値も読める。
  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard raw.hasPrefix("/"),
      !raw.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
      })
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "not a worktree path: \(raw)"))
    }
    path = raw
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

#if DEBUG
  extension TaskWorktree {
    /// 既に場所のキーであるパスをそのまま持つ（テストと見本の固定値用。ファイルシステムに触らない）。
    init(key: String) { path = key }
  }
#endif
