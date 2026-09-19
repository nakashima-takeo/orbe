import Foundation

/// `git for-each-ref` の `|` 区切り行を `GitBranch` へ落とすパーサ（local / remote）。
enum BranchParser {
  /// local: `%(refname:short)|%(committerdate:relative)|%(worktreepath)|%(upstream:short)|%(upstream)`
  /// `|%(upstream:remotename)|%(upstream:remoteref)|%(upstream:track)`。
  static func parseLocal(_ text: String) -> [GitBranch] {
    text.split(separator: "\n").compactMap { line in
      let f = String(line).components(separatedBy: "|")
      guard f.count >= 2, !f[0].isEmpty else { return nil }
      func field(_ i: Int) -> String? { f.count > i && !f[i].isEmpty ? f[i] : nil }
      let upstream = field(3).map { short in
        GitUpstream(
          short: short, ref: field(4) ?? "", remote: field(5) ?? "", remoteRef: field(6) ?? "",
          track: parseTrack(field(7)))
      }
      return GitBranch(
        name: f[0], relativeDate: f[1], worktreePath: field(2), upstream: upstream)
    }
  }

  /// `%(upstream:track)` の書式は固定（空 / `[gone]` / `[ahead N]` / `[behind M]` / `[ahead N, behind M]`）。
  private static func parseTrack(_ text: String?) -> GitUpstreamTrack? {
    guard let text else { return nil }
    if text == "[gone]" { return .gone }
    return .counts(ahead: count("ahead ", in: text), behind: count("behind ", in: text))
  }

  private static func count(_ label: String, in text: String) -> Int {
    guard let range = text.range(of: label) else { return 0 }
    return Int(text[range.upperBound...].prefix { $0.isNumber }) ?? 0
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
