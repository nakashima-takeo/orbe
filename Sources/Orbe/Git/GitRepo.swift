import Foundation

/// 1 つのチェックアウト（worktree 含む）に対する型付き git 操作。
/// 全メソッドは背景実行し、completion をメインキューで返す。
/// stage / unstage は index のみを書き、worktree のファイルへ書くのは
/// 明示的な確定操作（discard・conflict 解決の確定）だけ。
final class GitRepo {
  /// worktree のルート（rev-parse --show-toplevel）。
  let root: String
  /// このチェックアウトの git dir。linked worktree では本体側 worktrees/<name>/ を指す。
  let gitDir: String
  /// 共有 git dir（refs・objects の在処）。通常リポジトリでは gitDir と同じ。
  let commonDir: String

  private init(root: String, gitDir: String, commonDir: String) {
    self.root = root
    self.gitDir = gitDir
    self.commonDir = commonDir
  }

  /// cwd からチェックアウトを解決する。git リポジトリ外なら nil。
  static func open(cwd: String, completion: @escaping (GitRepo?) -> Void) {
    GitRunner.shared.run(
      ["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"], cwd: cwd
    ) { output in
      guard output.isSuccess else {
        completion(nil)
        return
      }
      let lines = output.stdoutText.split(separator: "\n").map(String.init)
      guard lines.count >= 3 else {
        completion(nil)
        return
      }
      // --git-common-dir は相対で返ることがある（cwd 基準）。絶対へ正規化する。
      let common =
        lines[2].hasPrefix("/")
        ? lines[2]
        : (cwd as NSString).appendingPathComponent(lines[2])
      completion(
        GitRepo(
          root: lines[0], gitDir: lines[1],
          commonDir: (common as NSString).standardizingPath))
    }
  }

  // MARK: - スナップショット

  /// status と staged / unstaged の全 diff をまとめて取る。
  struct Snapshot {
    let status: RepoStatus
    /// path → unstaged 差分（index ↔ worktree）。
    let unstaged: [String: FileDiff]
    /// path → staged 差分（HEAD ↔ index）。
    let staged: [String: FileDiff]
  }

  /// DiffParser が前提とする描画フラグ。snapshot（diff）と commitDiff（diff-tree）で共有する
  /// 単一ソース。信頼できないリポジトリ入力で diff driver / textconv 経由のコード実行を防ぎ、
  /// color.diff=always 下でも表示を壊さない。
  static let renderFlags = [
    "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames", "-U3",
  ]

  private static let diffArgs = ["diff"] + renderFlags

  func snapshot(completion: @escaping (Snapshot?) -> Void) {
    let group = DispatchGroup()
    var status: RepoStatus?
    var unstaged: [FileDiff] = []
    var staged: [FileDiff] = []
    var failed = false

    group.enter()
    GitRunner.shared.run(
      [
        "--no-optional-locks", "-c", "core.quotepath=false", "status", "--porcelain=v2",
        "--branch", "-z",
      ],
      cwd: root
    ) { output in
      if output.isSuccess { status = StatusParser.parse(output.stdout) } else { failed = true }
      group.leave()
    }

    group.enter()
    GitRunner.shared.run(["-c", "core.quotepath=false"] + Self.diffArgs, cwd: root) { output in
      if output.isSuccess { unstaged = DiffParser.parse(output.stdoutText) } else { failed = true }
      group.leave()
    }

    group.enter()
    GitRunner.shared.run(
      ["-c", "core.quotepath=false"] + Self.diffArgs + ["--cached"], cwd: root
    ) { output in
      if output.isSuccess { staged = DiffParser.parse(output.stdoutText) } else { failed = true }
      group.leave()
    }

    group.notify(queue: .main) {
      guard let status, !failed else {
        completion(nil)
        return
      }
      completion(
        Snapshot(
          status: status,
          unstaged: Dictionary(
            unstaged.map { ($0.displayPath, $0) }, uniquingKeysWith: { a, _ in a }),
          staged: Dictionary(
            staged.map { ($0.displayPath, $0) }, uniquingKeysWith: { a, _ in a })))
    }
  }

  // MARK: - index 操作（worktree 不可侵）

  /// 再構成パッチを index へ適用する（stage は forward、unstage は reverse）。
  /// 成功なら nil、失敗なら git のエラーメッセージ。
  func applyToIndex(patch: String, reverse: Bool, completion: @escaping (String?) -> Void) {
    var args = ["apply", "--cached", "--whitespace=nowarn"]
    if reverse { args.append("--reverse") }
    args.append("-")
    GitRunner.shared.run(args, cwd: root, stdin: Data(patch.utf8), write: true) { output in
      completion(output.isSuccess ? nil : output.stderrText)
    }
  }

  func stageFiles(_ paths: [String], completion: @escaping (String?) -> Void) {
    GitRunner.shared.run(["add", "--"] + paths, cwd: root, write: true) { output in
      completion(output.isSuccess ? nil : output.stderrText)
    }
  }

  /// 未追跡ファイルを intent-to-add で index に載せる（内容は載せない）。
  /// 部分 stage の前段で、パッチを適用できる土台を作る。
  func intentToAdd(_ paths: [String], completion: @escaping (String?) -> Void) {
    GitRunner.shared.run(
      ["add", "--intent-to-add", "--"] + paths, cwd: root, write: true
    ) { output in
      completion(output.isSuccess ? nil : output.stderrText)
    }
  }

  func unstageFiles(_ paths: [String], completion: @escaping (String?) -> Void) {
    GitRunner.shared.run(["reset", "-q", "--"] + paths, cwd: root, write: true) { [self] output in
      if output.isSuccess {
        completion(nil)
        return
      }
      // unborn HEAD（初回コミット前）では reset が HEAD を解決できない。
      // この場合のみ index からの除去で代替する（worktree のファイルは残る）。
      GitRunner.shared.run(
        ["rm", "--cached", "-q", "-r", "--ignore-unmatch", "--"] + paths, cwd: root, write: true
      ) { fallback in
        completion(fallback.isSuccess ? nil : fallback.stderrText)
      }
    }
  }

  // MARK: - 確定操作（worktree を書く）

  /// 選択行の worktree 変更を破棄する（unstaged diff からの再構成パッチを逆適用）。
  func discardPatch(_ patch: String, completion: @escaping (String?) -> Void) {
    GitRunner.shared.run(
      ["apply", "--reverse", "--whitespace=nowarn", "-"], cwd: root, stdin: Data(patch.utf8),
      write: true
    ) { output in
      completion(output.isSuccess ? nil : output.stderrText)
    }
  }

  /// ファイル単位の discard。追跡ファイルは index の内容へ戻し、未追跡は削除する。
  func discardFiles(
    tracked: [String], untracked: [String], completion: @escaping (String?) -> Void
  ) {
    let finish: (String?) -> Void = { [root] error in
      var failure = error
      for path in untracked {
        let full = (root as NSString).appendingPathComponent(path)
        do {
          try FileManager.default.removeItem(atPath: full)
        } catch {
          failure = (failure ?? "") + "\(path): \(error.localizedDescription)\n"
        }
      }
      completion(failure)
    }
    if tracked.isEmpty {
      finish(nil)
      return
    }
    GitRunner.shared.run(["checkout", "-q", "--"] + tracked, cwd: root, write: true) { output in
      finish(output.isSuccess ? nil : output.stderrText)
    }
  }

  // MARK: - コミット

  /// コミットする。hooks・署名は通常の git commit と同様に効く。
  /// 戻り値は (成功か, hooks 等の出力全文)。
  func commit(message: String, completion: @escaping (Bool, String) -> Void) {
    GitRunner.shared.run(
      ["commit", "-F", "-"], cwd: root, stdin: Data(message.utf8), write: true
    ) { output in
      let combined = [output.stdoutText, output.stderrText]
        .filter { !$0.isEmpty }.joined(separator: "\n")
      completion(output.isSuccess, combined)
    }
  }

  // MARK: - 履歴

  private static let logFormat = "--format=%H%x1f%h%x1f%an%x1f%at%x1f%P%x1f%D%x1f%s%x1e"

  func log(limit: Int, skip: Int = 0, completion: @escaping ([Commit]) -> Void) {
    GitRunner.shared.run(
      ["log", Self.logFormat, "-n", String(limit), "--skip", String(skip)], cwd: root
    ) { output in
      completion(output.isSuccess ? LogParser.parse(output.stdoutText) : [])
    }
  }

  /// upstream に未 push のコミット oid 集合（`rev-list @{upstream}..HEAD`）。
  /// upstream 不在・unborn なら空集合。
  func unpushedOids(completion: @escaping (Set<String>) -> Void) {
    GitRunner.shared.run(["rev-list", "@{upstream}..HEAD"], cwd: root) { output in
      guard output.isSuccess else {
        completion([])
        return
      }
      completion(Set(output.stdoutText.split(separator: "\n").map(String.init)))
    }
  }

  // MARK: - ファイルツリー

  /// worktree の全ファイル（追跡＋未追跡・ignore 除外）。失敗なら nil。
  func lsFiles(completion: @escaping ([String]?) -> Void) {
    GitRunner.shared.run(
      [
        "-c", "core.quotepath=false", "ls-files", "-z", "--cached", "--others",
        "--exclude-standard",
      ],
      cwd: root
    ) { output in
      guard output.isSuccess else {
        completion(nil)
        return
      }
      completion(
        output.stdout.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) })
    }
  }

  /// コミットの差分（path を渡すとそのファイルに限定）。
  func commitDiff(oid: String, path: String? = nil, completion: @escaping ([FileDiff]) -> Void) {
    var args =
      ["-c", "core.quotepath=false", "diff-tree", "--no-commit-id", "--patch", "--root"]
      + Self.renderFlags + [oid]
    if let path { args += ["--", path] }
    GitRunner.shared.run(args, cwd: root) { output in
      completion(output.isSuccess ? DiffParser.parse(output.stdoutText) : [])
    }
  }

  // MARK: - worktree 読み出し

  /// worktree のファイル内容（右ビューアのファイル表示・未追跡 diff 合成用）。
  func readWorktreeFile(path: String) -> String? {
    let full = (root as NSString).appendingPathComponent(path)
    return try? String(contentsOfFile: full, encoding: .utf8)
  }

  /// 未追跡ファイルの差分を合成する（`git diff` は未追跡を出さないため。
  /// テキストなら全行 added の 1 hunk）。
  /// 巨大物・バイナリは全読み・全行展開を避けて isBinary の空 hunk に落とす。
  func untrackedFileDiff(path: String) -> FileDiff? {
    let url = URL(fileURLWithPath: (root as NSString).appendingPathComponent(path))
    guard let data = try? Data(contentsOf: url) else { return nil }
    let binary = FileDiff(
      oldPath: nil, newPath: path, isBinary: true, oldMode: nil, newMode: nil,
      similarity: nil, hunks: [])
    // git と同じ流儀: 先頭 8000 バイトに NUL があればバイナリ扱い。巨大物・非 UTF-8 も同様。
    if data.prefix(8000).contains(0) || data.count > 5_000_000 { return binary }
    guard let text = String(bytes: data, encoding: .utf8) else { return binary }
    let endsWithNewline = text.hasSuffix("\n")
    var lines = text.components(separatedBy: "\n")
    if endsWithNewline { lines.removeLast() }
    let diffLines = lines.enumerated().map { i, line in
      DiffLine(
        kind: .added, text: line,
        noNewlineAtEnd: !endsWithNewline && i == lines.count - 1, newLine: i + 1)
    }
    return FileDiff(
      oldPath: nil, newPath: path, isBinary: false, oldMode: nil, newMode: "100644",
      similarity: nil,
      hunks: diffLines.isEmpty
        ? []
        : [
          Hunk(
            oldStart: 0, oldCount: 0, newStart: 1, newCount: diffLines.count,
            sectionHeading: "", lines: diffLines)
        ])
  }
}
