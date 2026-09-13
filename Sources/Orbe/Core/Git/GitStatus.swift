import Foundation

/// `git status --porcelain=v2 -z` の解析結果。根からの相対パスで引く。
struct GitStatus: Equatable {
  /// XY の 1 文字。`.`（変更なし）は nil。
  enum Change: Equatable {
    case modified, added, deleted, renamed, copied, typeChanged, unmerged, untracked
  }

  struct Entry: Equatable {
    let staged: Change?
    let unstaged: Change?

    var isConflicted: Bool { staged == .unmerged || unstaged == .unmerged }
  }

  /// ファイル 1 つに付く印。ディレクトリ行の集約は消費者が `entries` から導く。
  enum Badge: Equatable {
    case modified, added, untracked, conflicted
  }

  /// 相対パス → 変化（rename・copy は新しいパスで引く）。未追跡ディレクトリは含まない。
  let entries: [String: Entry]
  /// 未追跡のディレクトリ（末尾 `/` 無し）。中のファイルは status に個別に出ないので前方一致で引く。
  let untrackedDirectories: [String]

  /// 完全一致のエントリがあれば、競合 → conflicted、`unstaged ?? staged` が added → added、
  /// untracked → untracked、それ以外の変化 → modified。無ければ未追跡ディレクトリの中なら untracked。
  func badge(of relativePath: String) -> Badge? {
    if let entry = entries[relativePath] {
      if entry.isConflicted { return .conflicted }
      switch entry.unstaged ?? entry.staged {
      case .added: return .added
      case .untracked: return .untracked
      case .none: return nil
      default: return .modified
      }
    }
    let inside = untrackedDirectories.contains {
      relativePath == $0 || relativePath.hasPrefix($0 + "/")
    }
    return inside ? .untracked : nil
  }

  /// NUL 区切りの porcelain v2。`1`（通常）・`2`（rename・copy。次のトークンが元パス）・`u`（競合）・
  /// `?`（未追跡）を読み、`!`（ignored）・`#`（ヘッダ）・不正なトークンは捨てる。
  static func parse(_ data: Data) -> GitStatus {
    let tokens = data.split(separator: 0, omittingEmptySubsequences: false)
      .map { String(bytes: $0, encoding: .utf8) ?? "" }
    var entries: [String: Entry] = [:]
    var directories: [String] = []
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      index += 1
      switch token.prefix(2) {
      case "1 ":
        if let (path, entry) = ordinary(token) { entries[path] = entry }
      case "2 ":
        // 元パスは次のトークン。無ければ丸ごと捨てる。
        guard index < tokens.count else { break }
        index += 1
        if let (path, entry) = renamed(token) { entries[path] = entry }
      case "u ":
        if let path = unmerged(token) {
          entries[path] = Entry(staged: .unmerged, unstaged: .unmerged)
        }
      case "? ":
        let path = String(token.dropFirst(2))
        if path.hasSuffix("/") {
          directories.append(String(path.dropLast()))
        } else {
          entries[path] = Entry(staged: nil, unstaged: .untracked)
        }
      default:
        break
      }
    }
    return GitStatus(entries: entries, untrackedDirectories: directories)
  }

  /// `1 XY sub mH mI mW hH hI path`
  private static func ordinary(_ token: String) -> (String, Entry)? {
    let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
    guard fields.count == 9, let entry = pair(fields[1]) else { return nil }
    return (String(fields[8]), entry)
  }

  /// `2 XY sub mH mI mW hH hI Xscore path`
  private static func renamed(_ token: String) -> (String, Entry)? {
    let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
    guard fields.count == 10, let entry = pair(fields[1]) else { return nil }
    return (String(fields[9]), entry)
  }

  /// `u XY sub m1 m2 m3 mW h1 h2 h3 path`
  private static func unmerged(_ token: String) -> String? {
    let fields = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
    guard fields.count == 11 else { return nil }
    return String(fields[10])
  }

  private static func pair(_ xy: Substring) -> Entry? {
    let chars = Array(xy)
    guard chars.count == 2 else { return nil }
    return Entry(staged: change(chars[0]), unstaged: change(chars[1]))
  }

  private static func change(_ c: Character) -> Change? {
    switch c {
    case "M": return .modified
    case "A": return .added
    case "D": return .deleted
    case "R": return .renamed
    case "C": return .copied
    case "T": return .typeChanged
    case "U": return .unmerged
    default: return nil
    }
  }
}
