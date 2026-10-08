import Foundation

// MARK: - 観測（status・index の読み）

extension GitRepo {
  /// status の見え方を左右するユーザー設定を引数で封じる——`status.showUntrackedFiles`（未追跡はファイル単位）・
  /// `diff.ignoreSubmodules`・`status.aheadBehind`（先行/遅れは必ず数える）・`status.renames`（rename は必ず検出する）。
  /// ブランチのヘッダを必ず出す。`--no-optional-locks` で index を書き換えない。パスは `-z` で verbatim に出る
  /// （`core.quotepath` は参照されない）。
  static let statusArguments = [
    "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", "--ahead-behind",
    "--renames", "--untracked-files=all", "--ignore-submodules=none",
  ]

  /// worktree の status。git が失敗したら nil。解析は裏のスレッドで行う（未追跡が多いと出力が大きい）。
  func status(completion: @escaping (GitStatus?) -> Void) {
    runner.run(
      Self.statusArguments, cwd: root,
      transform: { $0.isSuccess ? GitStatus.parse($0.stdout) : nil }, completion: completion)
  }

  /// index にある blob の OID（相対パス → OID。stage 0 だけ＝競合中のパスは含まない）。
  /// 空の問い合わせは git を起こさない。git が失敗したら nil。
  ///
  /// パスはファイル名そのもの（ユーザーのデータ）なので pathspec として解釈させない——`:` 始まりは magic、
  /// `*` `[` は glob で、`:(` 始まりは fatal になって根の全 baseline が凍る。`:(literal)` を前置し、
  /// これを無効化する環境変数は `GitRunner` が落とす。
  func indexEntries(relativePaths: [String], completion: @escaping ([String: String]?) -> Void) {
    guard !relativePaths.isEmpty else {
      completion([:])
      return
    }
    runner.run(
      ["ls-files", "-s", "-z", "--"] + relativePaths.map { ":(literal)" + $0 }, cwd: root
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

  /// blob を作業ツリーに出したときの中身——`relativePath` の属性で smudge filter と eol 変換を掛けた
  /// バイト列（clean と smudge が往復する filter なら、git が clean と言う姿と同じ底）。smudge の実行コマンドは
  /// config 側にしか書けないので、信頼できないリポジトリのコードが実行される面は checkout と同じ。textconv・
  /// 外部 diff は通らない。git が失敗したら nil。
  func blob(oid: String, relativePath: String, completion: @escaping (Data?) -> Void) {
    runner.run(
      ["cat-file", "--filters", "--path=" + relativePath, oid], cwd: root
    ) { output in
      completion(output.isSuccess ? output.stdout : nil)
    }
  }
}
