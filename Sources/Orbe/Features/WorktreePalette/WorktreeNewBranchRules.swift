import Foundation

/// 作成行を出すかの、名前と作成先の衝突の規則。git の答え（ブランチ名として有効か）とは別に、
/// ぶつかる名前・作成先の作成行を出さない。
struct WorktreeNewBranchRules: Equatable {
  /// 作れない名前。ローカルブランチ（worktree で checkout 中のものを含む）と、リモートブランチの行が
  /// 作るローカル名——リモートブランチと同じ名前を別のベースから切ると、その行と同じ名前の別物になる。
  let takenNames: Set<String>
  /// 既存の worktree のパス（`canonical` で解いた値）。
  let worktreePaths: Set<String>
  /// 作成先のテンプレート（設定 `worktree-dir` の実効値）と、それを解決する repo の場所。
  let template: String
  let repoPath: String

  /// `remoteBranches` はリモートブランチの名前（`origin/feat/x`）。
  init(
    localBranches: [String], remoteBranches: [String], worktreePaths: [String], template: String,
    repoPath: String
  ) {
    takenNames = Set(localBranches).union(remoteBranches.map(GitBranch.localName(fromRemote:)))
    self.worktreePaths = Set(worktreePaths.map(Self.canonical))
    self.template = template
    self.repoPath = repoPath
  }

  /// その名前の作成行を出してよいか。作成先が既存の worktree と同じ場所になる名前（`issue-212` と
  /// `issue/212` は同じ slug）は、作成が必ず失敗するので出さない。
  func allows(_ name: String) -> Bool {
    guard !takenNames.contains(name) else { return false }
    let path = WorktreePathTemplate.resolve(
      template: template, repoPath: repoPath, slug: WorktreePathTemplate.slug(forBranch: name))
    return !worktreePaths.contains(Self.canonical(path))
  }

  /// 同じ場所かを比べる形。実在する祖先までを `GitWorktreeRoot.normalizedPath`（symlink と
  /// `/private` を畳む、パスの突き合わせの共有の正準形）で解き、まだ無い末尾はそのまま足す。作成先は
  /// これから作るので末尾が実在せず、`normalizedPath` だけでは symlink 配下の祖先が解けない——一方
  /// `git worktree list` は実パスを返すことも、登録時の symlink 経由のパスを返すこともあり、実体が
  /// 消えた登録（git は同じ場所への作成を拒む）は実在しない。両辺を祖先まで解いて同じ土俵に乗せる。
  private static func canonical(_ path: String) -> String {
    var existing = path
    var tail: [String] = []
    while !FileManager.default.fileExists(atPath: existing) {
      let parent = (existing as NSString).deletingLastPathComponent
      guard parent != existing else { break }
      tail.insert((existing as NSString).lastPathComponent, at: 0)
      existing = parent
    }
    return tail.reduce(GitWorktreeRoot.normalizedPath(existing)) {
      ($0 as NSString).appendingPathComponent($1)
    }
  }
}
