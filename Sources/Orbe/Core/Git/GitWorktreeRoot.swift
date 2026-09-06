import Foundation

/// cwd が属する git worktree ルートを、`.git`（ディレクトリでも file でも＝linked worktree は file）を
/// 親方向へ探して同期で求める。サブプロセスを使わない（OSC 7 はプロンプトごとに届く）。
enum GitWorktreeRoot {
  /// 実パス正規化（standardizingPath → resolvingSymlinksInPath）。OSC 7 の論理パス・復元 cwd・
  /// `git worktree list` のパスを同じ土俵に乗せる唯一の実装（macOS では `/tmp` `/var` が symlink）。
  static func normalizedPath(_ path: String) -> String {
    ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
  }

  /// 正規化した cwd から自身を含めて `/` まで上へ辿り、最初に `.git` を持つディレクトリ。無ければ nil。
  /// 存在しないパス（消えた worktree）は `.git` が見つからないまま祖先へ上がるだけ。
  static func locate(cwd: String) -> String? {
    var dir = normalizedPath(cwd)
    while true {
      if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
        return dir
      }
      let parent = (dir as NSString).deletingLastPathComponent
      guard parent != dir else { return nil }
      dir = parent
    }
  }
}
