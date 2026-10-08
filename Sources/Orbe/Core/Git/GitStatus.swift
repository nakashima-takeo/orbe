import Foundation

/// `git status --porcelain=v2 -z --branch` の解析結果。ファイルは根からの相対パスで引く。
struct GitStatus: Equatable {
  /// XY の 1 文字。`.`（変更なし）は nil。
  enum Change: Equatable {
    case modified, added, deleted, renamed, copied, typeChanged, unmerged, untracked
  }

  struct Entry: Equatable {
    let staged: Change?
    let unstaged: Change?
    /// rename・copy の元パス。
    let originalPath: String?

    init(staged: Change?, unstaged: Change?, originalPath: String? = nil) {
      self.staged = staged
      self.unstaged = unstaged
      self.originalPath = originalPath
    }

    var isConflicted: Bool { staged == .unmerged || unstaged == .unmerged }
  }

  /// 今のブランチ。HEAD・upstream が動けば値が変わる。
  struct Branch: Equatable {
    /// ブランチ名。nil = detached。
    let name: String?
    /// HEAD のコミット。nil = 初回コミット前。
    let commit: String?
    let upstream: Upstream?
  }

  struct Upstream: Equatable {
    /// git の短い名前（`origin/main`）。
    let name: String
    /// 先行/遅れの数。nil = 不明（upstream の ref が消えた）。
    let divergence: Divergence?
  }

  struct Divergence: Equatable {
    let ahead: Int
    let behind: Int
  }

  /// status の 1 行が指すパス。操作（ステージ・解除・破棄）は元パスも同じ操作に含める——rename の行を解除すると、
  /// 元パスの削除の側も解除される。
  struct Row: Hashable {
    let path: String
    let originalPath: String?

    var paths: [String] { [path] + (originalPath.map { [$0] } ?? []) }
  }

  /// ファイル 1 つに付く印。ディレクトリ行の集約は消費者が `entries` から導く。
  enum Badge: Equatable {
    case modified, added, untracked, conflicted
  }

  /// 相対パス → 変化（rename・copy は新しいパスで引く）。未追跡はファイル 1 件ずつ。
  let entries: [String: Entry]
  /// 未追跡のディレクトリ（末尾 `/` 無し）。未追跡の入れ子のリポジトリだけが git にこの形で出る（中は個別に出ない
  /// ので前方一致で引く）。
  let untrackedDirectories: [String]
  /// ブランチのヘッダが無い出力なら nil。
  let branch: Branch?

  init(entries: [String: Entry], untrackedDirectories: [String], branch: Branch? = nil) {
    self.entries = entries
    self.untrackedDirectories = untrackedDirectories
    self.branch = branch
  }

  /// その相対パスの行（rename・copy なら元パスも）。
  func row(_ path: String) -> Row {
    Row(path: path, originalPath: entries[path]?.originalPath)
  }

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
  /// `?`（未追跡）・`# branch.*`（ブランチのヘッダ）を読み、`!`（ignored）・他のヘッダ・不正なトークンは捨てる。
  static func parse(_ data: Data) -> GitStatus {
    let tokens = data.split(separator: 0, omittingEmptySubsequences: false)
      .map { String(bytes: $0, encoding: .utf8) ?? "" }
    var entries: [String: Entry] = [:]
    var directories: [String] = []
    var headers = BranchHeaders()
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      index += 1
      switch token.prefix(2) {
      case "# ":
        headers.read(token)
      case "1 ":
        if let (path, entry) = ordinary(token) { entries[path] = entry }
      case "2 ":
        // 元パスは次のトークン。無ければ丸ごと捨てる。
        guard index < tokens.count else { break }
        let original = tokens[index]
        index += 1
        if let (path, entry) = renamed(token, from: original) { entries[path] = entry }
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
    return GitStatus(entries: entries, untrackedDirectories: directories, branch: headers.branch)
  }

  /// `# branch.oid <commit | (initial)>`・`# branch.head <name | (detached)>`・`# branch.upstream <name>`・
  /// `# branch.ab +A -B`。upstream が在って `branch.ab` が無いのは、upstream の ref が消えたとき。
  private struct BranchHeaders {
    var oid: String?
    var head: String?
    var upstream: String?
    var divergence: Divergence?

    mutating func read(_ token: String) {
      let fields = token.split(separator: " ", maxSplits: 2)
      guard fields.count == 3 else { return }
      let value = String(fields[2])
      switch fields[1] {
      case "branch.oid": oid = value
      case "branch.head": head = value
      case "branch.upstream": upstream = value
      case "branch.ab":
        let counts = value.split(separator: " ")
        guard counts.count == 2, let ahead = Int(counts[0].dropFirst()),
          let behind = Int(counts[1].dropFirst())
        else { return }
        divergence = Divergence(ahead: ahead, behind: behind)
      default: break
      }
    }

    var branch: Branch? {
      guard let oid, let head else { return nil }
      return Branch(
        name: head == "(detached)" ? nil : head, commit: oid == "(initial)" ? nil : oid,
        upstream: upstream.map { Upstream(name: $0, divergence: divergence) })
    }
  }

  /// `1 XY sub mH mI mW hH hI path`
  private static func ordinary(_ token: String) -> (String, Entry)? {
    let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
    guard fields.count == 9, let entry = pair(fields[1]) else { return nil }
    return (String(fields[8]), entry)
  }

  /// `2 XY sub mH mI mW hH hI Xscore path`（元パスは次のトークン）
  private static func renamed(_ token: String, from original: String) -> (String, Entry)? {
    let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
    guard fields.count == 10, let entry = pair(fields[1]) else { return nil }
    return (
      String(fields[9]),
      Entry(staged: entry.staged, unstaged: entry.unstaged, originalPath: original)
    )
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
