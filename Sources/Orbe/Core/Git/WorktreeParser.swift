import Foundation

/// `git worktree list --porcelain` の出力をパースする。
/// 各チェックアウトは空行で区切られ、`worktree <path>` / `HEAD <oid>` / `branch <ref>` / `detached` を持つ。
/// 先頭ブロックが本体（main）worktree（git は main を最初に列挙する）。
enum WorktreeParser {
  static func parse(_ text: String) -> [GitWorktree] {
    var out: [GitWorktree] = []
    var isFirst = true
    for block in text.components(separatedBy: "\n\n") {
      var path: String?
      var head = ""
      var branch: String?
      for line in block.split(separator: "\n") {
        if line.hasPrefix("worktree ") {
          path = String(line.dropFirst("worktree ".count))
        } else if line.hasPrefix("HEAD ") {
          head = String(line.dropFirst("HEAD ".count))
        } else if line.hasPrefix("branch ") {
          let ref = String(line.dropFirst("branch ".count))
          branch =
            ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
      }
      guard let path else { continue }
      out.append(GitWorktree(path: path, branch: branch, head: head, isMain: isFirst))
      isFirst = false
    }
    return out
  }
}
