import Foundation

/// origin（bare の `origin.git`）と、それを clone した手元（`web`）と、origin を進める clone（`other`）の組。手元の `stale` は
/// origin の `stale` を追跡し、1 コミット遅れる。コミットはどれも空。
enum StaleCloneFixture {
  /// 組の複製を `dir`（まだ無いパス）に置き、`web` と `other` の origin を、複製の中の `origin.git` へ向け直す。
  static func place(at dir: URL) throws {
    try template.copy(to: dir)
    let origin = dir.appendingPathComponent("origin.git").path
    for clone in ["web", "other"] {
      try GitFixtureTemplate.git(
        ["remote", "set-url", "origin", origin], in: dir.appendingPathComponent(clone).path)
    }
  }

  private nonisolated(unsafe) static let template = GitFixtureTemplate(
    name: "orbe-stale-clone", build: build)

  private static func build(_ dir: URL) throws {
    let origin = dir.appendingPathComponent("origin.git").path
    let local = dir.appendingPathComponent("web").path
    let other = dir.appendingPathComponent("other").path
    func git(_ args: [String], in cwd: String) throws {
      try GitFixtureTemplate.git(args, in: cwd)
    }
    func identify(_ repo: String) throws {
      try git(["config", "user.email", "t@example.com"], in: repo)
      try git(["config", "user.name", "t"], in: repo)
    }
    try git(["init", "-q", "--bare", "-b", "main", origin], in: dir.path)
    try git(["clone", "-q", origin, other], in: dir.path)
    try identify(other)
    try git(["commit", "-q", "--allow-empty", "-m", "a"], in: other)
    try git(["push", "-q", "origin", "HEAD:main", "HEAD:stale"], in: other)
    try git(["clone", "-q", origin, local], in: dir.path)
    try identify(local)
    try git(["branch", "-q", "--track", "stale", "origin/stale"], in: local)
    try git(["commit", "-q", "--allow-empty", "-m", "b"], in: other)
    try git(["push", "-q", "origin", "HEAD:stale"], in: other)
  }
}
