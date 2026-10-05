import Foundation

/// 作成行を出すかの、名前と作成先の衝突の規則。git の答え（ブランチ名として有効か）とは別に、
/// ぶつかる名前・作成先の作成行を出さない。
struct WorktreeNewBranchRules: Equatable {
  /// ローカルブランチの名前（worktree で checkout 中のものを含む）。
  let localNames: Set<String>
  /// 作れない名前。ローカルブランチと、リモートブランチの行が作るローカル名——リモートブランチと同じ名前を
  /// 別のベースから切ると、その行と同じ名前の別物になる。
  let takenNames: Set<String>
  /// リモートブランチの列挙が、提示時の `fetch --prune` の着地後の値か。着地前は、作れる名前もリモートに
  /// 現れうる（現れれば正しい入口はそのリモートブランチの行で、同じ名前の別物を作らない）。
  let remoteBranchesLanded: Bool
  /// 既存の worktree のパス（`canonical` で解いた値）。
  let worktreePaths: Set<String>
  /// 作成先のテンプレート（設定 `worktree-dir` の実効値）と、それを解決する repo の場所。
  let template: String
  let repoPath: String

  /// `remoteBranches` はリモートブランチの名前（`origin/feat/x`）。
  init(
    localBranches: [String], remoteBranches: [String], remoteBranchesLanded: Bool,
    worktreePaths: [String], template: String, repoPath: String
  ) {
    localNames = Set(localBranches)
    takenNames = localNames.union(remoteBranches.map(GitBranch.localName(fromRemote:)))
    self.remoteBranchesLanded = remoteBranchesLanded
    self.worktreePaths = Set(worktreePaths.map(Self.canonical))
    self.template = template
    self.repoPath = repoPath
  }

  /// その名前の作成行を出してよいか。ローカルブランチと親子になる名前（`fix/login-blank` があるときの `fix`、
  /// `fix/login-blank/sub`）は、git の ref が親子の名前を同時に持てず作成が必ず失敗するので出さない。作成先が
  /// 既存の worktree と同じ場所になる名前（`issue-212` と `issue/212` は同じ slug）も、作成が必ず失敗するので
  /// 出さない。
  func allows(_ name: String) -> Bool {
    guard !takenNames.contains(name),
      !localNames.contains(where: { $0.hasPrefix(name + "/") || name.hasPrefix($0 + "/") })
    else { return false }
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
