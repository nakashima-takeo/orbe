import Foundation

/// worktree を作業ツリーの**中**に作るときの除外。repo 内配置を設定で選べる以上、`git status` が
/// worktree ぶんだけ汚れる（`git add .` が gitlink 化する）のを注意書きでなく自動化で塞ぐ。
///
/// 判定は解決済みパスだけで行い、UI の行（プリセット／カスタム）には副作用を紐付けない。
/// 書き先は `$GIT_COMMON_DIR/info/exclude`——全 worktree 共有なのでどのチェックアウトでも効く
/// （per-worktree の exclude は他の worktree に効かないため使わない）。ユーザーの `.gitignore` は
/// 書き換えない（コミット対象を勝手に増やさない）。
enum GitWorktreeExclude {
  /// `.git/info/exclude` へ入れる除外 1 件。
  struct Entry: Equatable {
    /// 除外対象ディレクトリ（作業ツリー root からの相対）。`git check-ignore` の判定対象。
    let relativePath: String
    /// gitignore パターン（root 起点アンカー・ディレクトリ限定）。
    var pattern: String { "/\(relativePath)/" }
  }

  /// 追記行の由来を人が読めるようにする見出し（この 1 行だけで `.git/info/exclude` の出所が分かる）。
  static let comment = "# Orbe: worktree location"

  /// 解決済み worktree パスが作業ツリー内に入るなら除外 1 件を返す（外なら nil＝何もしない）。
  ///
  /// 対象は worktree の**親ディレクトリ**（＝以後そこに増える worktree も 1 行で覆う容れ物）。
  /// ただし親が root 自身になる配置（`{parent}/{repo}-{slug}` を repo 内に向けた形など）では
  /// worktree ディレクトリ自身を対象にする——root 全体を除外しては本末転倒なため。
  static func entry(worktreePath: String, worktreeRoot: String) -> Entry? {
    // 作成先の解決と同じ純字句の正規化を通す（実在有無で答えが変わらない＝両者が同じ土俵に乗る）。
    let root = WorktreePathTemplate.standardized(worktreeRoot)
    let path = WorktreePathTemplate.standardized(worktreePath)
    guard path.hasPrefix(root + "/") else { return nil }
    let components = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    guard !components.isEmpty else { return nil }
    let target = components.count == 1 ? components : Array(components.dropLast())
    return Entry(relativePath: target.joined(separator: "/"))
  }

  /// 共有 exclude へ冪等に追記する（同じパターンの行が既にあれば何もしない）。書けなければ false
  /// ——除外は補助であり worktree 作成の前提条件ではないので、呼び出し側は失敗しても続行する。
  @discardableResult
  static func append(_ entry: Entry, toCommonDir commonDir: String) -> Bool {
    let infoDir = (commonDir as NSString).appendingPathComponent("info")
    let file = (infoDir as NSString).appendingPathComponent("exclude")
    let existing = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
    let alreadyListed = existing.split(separator: "\n", omittingEmptySubsequences: false)
      .contains { $0.trimmingCharacters(in: .whitespaces) == entry.pattern }
    if alreadyListed { return true }
    try? FileManager.default.createDirectory(
      atPath: infoDir, withIntermediateDirectories: true)
    let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
    let updated = existing + separator + "\(comment)\n\(entry.pattern)\n"
    do {
      try updated.write(toFile: file, atomically: true, encoding: .utf8)
    } catch {
      return false
    }
    return true
  }
}

extension GitRepo {
  /// worktree 作成先が作業ツリー内に落ちる場合だけ、共有 exclude へ除外を冪等に入れる。
  /// 既に無視されている（ユーザーの `.gitignore` 由来を含む）なら触らない。
  /// 除外は補助なので、判定・追記の成否にかかわらず completion は必ず呼ぶ（作成は続行する）。
  func excludeWorktreeIfInside(
    path: String, worktreeRoot: String, completion: @escaping () -> Void
  ) {
    guard let entry = GitWorktreeExclude.entry(worktreePath: path, worktreeRoot: worktreeRoot)
    else {
      completion()
      return
    }
    let commonDir = commonDir
    // exit 0＝既に無視。exit 1（未無視）と判定不能はどちらも追記を試みる（追記自体が冪等）。
    GitRunner.shared.run(
      ["check-ignore", "-q", "--", entry.relativePath], cwd: worktreeRoot
    ) { output in
      if !output.isSuccess {
        GitWorktreeExclude.append(entry, toCommonDir: commonDir)
      }
      completion()
    }
  }
}
