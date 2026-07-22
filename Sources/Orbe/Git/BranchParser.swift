import Foundation

/// `git for-each-ref` の `|` 区切り行を `GitBranch` へ落とすパーサ（local / remote）。
enum BranchParser {
  /// local: `%(refname:short)|%(committerdate:relative)|%(worktreepath)|%(upstream:short)`。
  static func parseLocal(_ text: String) -> [GitBranch] {
    text.split(separator: "\n").compactMap { line in
      let f = String(line).components(separatedBy: "|")
      guard f.count >= 2, !f[0].isEmpty else { return nil }
      return GitBranch(
        name: f[0],
        relativeDate: f[1],
        worktreePath: f.count > 2 && !f[2].isEmpty ? f[2] : nil,
        upstream: f.count > 3 && !f[3].isEmpty ? f[3] : nil)
    }
  }

  /// remote: `%(refname:short)|%(committerdate:relative)|%(authorname)`。
  /// `refs/remotes/origin/HEAD` の短縮（`origin` 単独）や `*/HEAD` 行はノイズとして除外する。
  static func parseRemote(_ text: String) -> [GitBranch] {
    text.split(separator: "\n").compactMap { line -> GitBranch? in
      let f = String(line).components(separatedBy: "|")
      guard let name = f.first, !name.isEmpty else { return nil }
      guard name.contains("/"), !name.hasSuffix("/HEAD") else { return nil }
      let date = f.count > 1 ? f[1] : ""
      let author = f.count > 2 ? f[2] : ""
      let combined: String
      if author.isEmpty {
        combined = date
      } else if date.isEmpty {
        combined = author
      } else {
        combined = "\(author) · \(date)"
      }
      return GitBranch(name: name, relativeDate: combined, worktreePath: nil, upstream: nil)
    }
  }
}
