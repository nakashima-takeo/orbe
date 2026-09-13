import Foundation

// MARK: - 観測（status・index の読み）

/// 結果が古くても監視が取り直す観測。`.independent` で走らせ、巨大リポジトリの status が
/// `.exclusive`（worktree remove・update-ref）を待たせないようにする。
extension GitRepo {
  /// status の見え方を左右するユーザー設定（`status.showUntrackedFiles`・`core.quotepath`・
  /// `diff.ignoreSubmodules`）を引数で封じ、`--no-optional-locks` で index を書き換えない。
  static let statusArguments = [
    "--no-optional-locks", "-c", "core.quotepath=false", "status", "--porcelain=v2", "-z",
    "--untracked-files=normal", "--ignore-submodules=none",
  ]

  /// worktree の status。git が失敗したら nil。
  func status(completion: @escaping (GitStatus?) -> Void) {
    runner.run(Self.statusArguments, cwd: root, lane: .independent) { output in
      completion(output.isSuccess ? GitStatus.parse(output.stdout) : nil)
    }
  }

  /// index にある blob の OID（相対パス → OID。stage 0 だけ＝競合中のパスは含まない）。
  /// 空の問い合わせは git を起こさない。git が失敗したら nil。
  func indexEntries(relativePaths: [String], completion: @escaping ([String: String]?) -> Void) {
    guard !relativePaths.isEmpty else {
      completion([:])
      return
    }
    runner.run(
      ["ls-files", "-s", "-z", "--"] + relativePaths, cwd: root, lane: .independent
    ) { output in
      guard output.isSuccess else {
        completion(nil)
        return
      }
      var entries: [String: String] = [:]
      for record in output.stdout.split(separator: 0) {
        // `<mode> <oid> <stage>\t<path>`
        guard let line = String(bytes: record, encoding: .utf8),
          let tab = line.firstIndex(of: "\t")
        else { continue }
        let fields = line[..<tab].split(separator: " ")
        guard fields.count == 3, fields[2] == "0" else { continue }
        entries[String(line[line.index(after: tab)...])] = String(fields[1])
      }
      completion(entries)
    }
  }

  /// blob の中身。filter・textconv・外部 diff を通らない生のバイト列。git が失敗したら nil。
  func blob(oid: String, completion: @escaping (Data?) -> Void) {
    runner.run(["cat-file", "blob", oid], cwd: root, lane: .independent) { output in
      completion(output.isSuccess ? output.stdout : nil)
    }
  }
}
