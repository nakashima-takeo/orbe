import Foundation

/// `git worktree list --porcelain -z` の出力をパースする。
/// 各行は NUL 終端で、チェックアウトの終わりに空の行（もう 1 つの NUL）が付く。パスにも `locked` /
/// `prunable` の理由にも LF が入りうるので、LF 区切りの `--porcelain` ではなくこの形で読む。
/// 各チェックアウトは `worktree <path>` / `HEAD <oid>` / `branch <ref>` / `detached` /
/// `locked [reason]` / `prunable <reason>` を持つ。
/// 先頭ブロックが本体（main）worktree（git は main を最初に列挙する）。
enum WorktreeParser {
  /// 出力の形を決める `git worktree list` のオプション。
  static let listOptions = ["--porcelain", "-z"]

  static func parse(_ text: String) -> [GitWorktree] {
    var out: [GitWorktree] = []
    var isFirst = true
    for block in text.components(separatedBy: "\0\0") {
      var path: String?
      var head = ""
      var branch: String?
      var isPrunable = false
      var lockReason: String?
      for line in block.split(separator: "\0") {
        if line.hasPrefix("worktree ") {
          path = String(line.dropFirst("worktree ".count))
        } else if line.hasPrefix("HEAD ") {
          head = String(line.dropFirst("HEAD ".count))
        } else if line.hasPrefix("branch ") {
          let ref = String(line.dropFirst("branch ".count))
          branch =
            ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        } else if line == "prunable" || line.hasPrefix("prunable ") {
          isPrunable = true
        } else if line == "locked" || line.hasPrefix("locked ") {
          // 理由は任意（`locked` 単独の行もある）。理由の有無に依らず locked である事実を持つ。
          lockReason = String(line.dropFirst("locked".count)).trimmingCharacters(in: .whitespaces)
        }
      }
      guard let path else { continue }
      out.append(
        GitWorktree(
          path: path, branch: branch, head: head, isMain: isFirst,
          isPrunable: isPrunable, lockReason: lockReason))
      isFirst = false
    }
    return out
  }
}
