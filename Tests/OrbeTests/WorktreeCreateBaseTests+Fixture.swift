import Foundation

@testable import Orbe

extension WorktreeCreateBaseTests {
  /// `main` / `feat` / `stale` を持つ origin（`origin.git`）と、手元の clone（`local`）と、origin を進める clone（`other`）の組。
  /// 手元の remote 追跡 ref は**わざと古いまま**にする。`mine` は upstream の無い手元だけのローカルブランチ（着地を待たない題材）、
  /// `stale` は origin を追跡する手元のブランチ（分冊 `+Refresh` の題材）。複製の後、`local` と `other` の origin を
  /// 複製の中の `origin.git` へ向け直す。
  nonisolated(unsafe) static let pair = GitFixtureTemplate(name: "orbe-wtbase", build: buildPair)

  private nonisolated static func buildPair(_ dir: URL) throws {
    let origin = dir.appendingPathComponent("origin.git").path
    let local = dir.appendingPathComponent("local").path
    let other = dir.appendingPathComponent("other").path
    @discardableResult
    func git(_ args: [String], in cwd: String) throws -> String {
      try GitFixtureTemplate.git(args, in: cwd).stdoutText
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func identify(_ repo: String) throws {
      try git(["config", "user.email", "t@example.com"], in: repo)
      try git(["config", "user.name", "t"], in: repo)
    }
    func commit(_ name: String, in repo: String) throws {
      try name.write(
        toFile: (repo as NSString).appendingPathComponent("\(name).txt"), atomically: true,
        encoding: .utf8)
      try git(["add", "-A"], in: repo)
      try git(["commit", "-qm", name], in: repo)
    }

    try git(["init", "-q", "--bare", "-b", "main", origin], in: dir.path)
    try git(["init", "-q", "-b", "main", local], in: dir.path)
    try identify(local)
    try commit("a", in: local)
    try git(["remote", "add", "origin", origin], in: local)
    try git(["push", "-q", "-u", "origin", "main"], in: local)
    try git(["branch", "mine", "main"], in: local)

    try git(["clone", "-q", origin, other], in: dir.path)
    try identify(other)
    for branch in ["feat", "stale"] {
      try git(["checkout", "-q", "-b", branch, "main"], in: other)
      try commit("\(branch)-1", in: other)
      try git(["push", "-q", "-u", "origin", branch], in: other)
    }

    // ここまでを手元へ取り込み、`origin/HEAD` を据える（通常の clone と同じ形）。
    try git(["fetch", "-q", "origin"], in: local)
    try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: local)
    // `stale` は origin を追跡する手元のブランチ（checkout していない＝Local branch 行の題材）。
    try git(["branch", "-q", "--track", "stale", "origin/stale"], in: local)

    // 以降の origin 側の前進は手元に入らない＝手元の remote 追跡 ref は古い。
    for branch in ["main", "feat", "stale"] {
      try git(["checkout", "-q", branch], in: other)
      try commit("\(branch)-2", in: other)
      try git(["push", "-q", "origin", branch], in: other)
      guard
        try git(["rev-parse", branch], in: origin)
          != git(["rev-parse", "origin/\(branch)"], in: local)
      else { throw GitFixtureTemplate.Failure(description: "前提: 手元の origin/\(branch) は古い") }
    }
  }
}
