import Foundation

/// `git status --porcelain=v2 --branch -z` の出力をパースする。
/// -z モードは各レコードを NUL で終端し、rename/copy の origPath は path の次の独立フィールドで続く。
enum StatusParser {
  static func parse(_ data: Data) -> RepoStatus {
    // デコード不能なフィールドは空文字列にし、後段の不正エントリ扱いで読み飛ばす（位置は保つ）。
    let tokens = data.split(separator: 0, omittingEmptySubsequences: false)
      .map { String(bytes: $0, encoding: .utf8) ?? "" }

    var header = BranchHeader()
    var files: [FileChange] = []

    var i = 0
    while i < tokens.count {
      let token = tokens[i]
      i += 1
      if token.hasPrefix("# ") {
        parseHeader(token, into: &header)
      } else if token.hasPrefix("1 ") {
        if let file = parseOrdinary(token) { files.append(file) }
      } else if token.hasPrefix("2 ") {
        // origPath は次の NUL 区切りフィールド。欠けたエントリは丸ごと読み飛ばす。
        if i < tokens.count, let file = parseRenamed(token, origPath: tokens[i]) {
          files.append(file)
          i += 1
        }
      } else if token.hasPrefix("u ") {
        if let file = parseUnmerged(token) { files.append(file) }
      } else if token.hasPrefix("? ") {
        files.append(
          FileChange(
            path: String(token.dropFirst(2)), oldPath: nil, staged: nil, unstaged: .untracked))
      }
      // "! "（ignored）・空フィールド・不正エントリは読み飛ばす
    }
    return RepoStatus(
      branch: header.branch, oid: header.oid, upstream: header.upstream,
      ahead: header.ahead, behind: header.behind, files: files)
  }

  /// `# branch.*` ヘッダの集積先。
  private struct BranchHeader {
    var branch: String?
    var oid: String?
    var upstream: String?
    var ahead: Int?
    var behind: Int?
  }

  /// `# branch.head` / `# branch.oid` / `# branch.upstream` / `# branch.ab +A -B`。
  /// それ以外のヘッダは使わない。
  private static func parseHeader(_ token: String, into header: inout BranchHeader) {
    let headPrefix = "# branch.head "
    let oidPrefix = "# branch.oid "
    let upstreamPrefix = "# branch.upstream "
    let abPrefix = "# branch.ab "
    if token.hasPrefix(headPrefix) {
      let value = String(token.dropFirst(headPrefix.count))
      header.branch = value == "(detached)" ? nil : value
    } else if token.hasPrefix(oidPrefix) {
      let value = String(token.dropFirst(oidPrefix.count))
      header.oid = value == "(initial)" ? nil : value
    } else if token.hasPrefix(upstreamPrefix) {
      header.upstream = String(token.dropFirst(upstreamPrefix.count))
    } else if token.hasPrefix(abPrefix) {
      // `+A -B`。upstream が消えている等で形が崩れていたら nil のまま残す。
      let parts = token.dropFirst(abPrefix.count).split(separator: " ")
      guard parts.count == 2, parts[0].hasPrefix("+"), parts[1].hasPrefix("-"),
        let a = Int(parts[0].dropFirst()), let b = Int(parts[1].dropFirst())
      else { return }
      header.ahead = a
      header.behind = b
    }
  }

  /// `1 XY sub mH mI mW hH hI path`
  private static func parseOrdinary(_ token: String) -> FileChange? {
    let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
    guard fields.count == 9, let xy = statusPair(fields[1]) else { return nil }
    return FileChange(
      path: String(fields[8]), oldPath: nil, staged: xy.staged, unstaged: xy.unstaged)
  }

  /// `2 XY sub mH mI mW hH hI Xscore path`
  private static func parseRenamed(_ token: String, origPath: String) -> FileChange? {
    let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
    guard fields.count == 10, !origPath.isEmpty, let xy = statusPair(fields[1]) else { return nil }
    return FileChange(
      path: String(fields[9]), oldPath: origPath, staged: xy.staged, unstaged: xy.unstaged)
  }

  /// `u XY sub m1 m2 m3 mW h1 h2 h3 path`。両側 unmerged として扱う。
  private static func parseUnmerged(_ token: String) -> FileChange? {
    let fields = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
    guard fields.count == 11 else { return nil }
    return FileChange(
      path: String(fields[10]), oldPath: nil, staged: .unmerged, unstaged: .unmerged)
  }

  /// XY 2 文字を staged / unstaged に分解する。
  private static func statusPair(
    _ xy: Substring
  ) -> (staged: FileChange.Status?, unstaged: FileChange.Status?)? {
    let chars = Array(xy)
    guard chars.count == 2 else { return nil }
    return (status(chars[0]), status(chars[1]))
  }

  private static func status(_ c: Character) -> FileChange.Status? {
    switch c {
    case "M": return .modified
    case "A": return .added
    case "D": return .deleted
    case "R": return .renamed
    case "C": return .copied
    case "T": return .typeChanged
    case "U": return .unmerged
    default: return nil  // "." は変更なし。未知の文字も無理に解釈しない
    }
  }
}
