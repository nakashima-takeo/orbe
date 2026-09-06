import Foundation

/// cwd が属する git worktree ルートを、`.git`（ディレクトリでも file でも＝linked worktree は file）を
/// 親方向へ探して同期で求める。サブプロセスを使わない（OSC 7 はプロンプトごとに届く）。
enum GitWorktreeRoot {
  /// 比較用の正準形（standardizingPath → resolvingSymlinksInPath）。symlink を解いたうえで先頭の
  /// `/private` を畳むので、返るのは実パスではなく短縮形（`/private/tmp` → `/tmp`）。OSC 7 の論理パス・
  /// 復元 cwd・`git worktree list` のパスを同じ土俵に乗せる唯一の実装（macOS では `/tmp` `/var` が symlink）。
  /// どちらの変換も**実在する部分にしか効かない**ので、不在パスは末尾がそのまま残る。
  static func normalizedPath(_ path: String) -> String {
    ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
  }

  /// 正規化した cwd から自身を含めて `/` まで上へ辿り、最初に `.git` を持つディレクトリ（正準形）。
  /// 無ければ nil。存在しないパス（消えた worktree）は `.git` が見つからないまま祖先へ上がるだけ——
  /// cwd が不在だと入口の正規化は効かないので、見つけたルートを改めて正準化して返す（`.git` が
  /// 見えた時点でそのディレクトリは実在する）。
  static func locate(cwd: String) -> String? {
    var dir = normalizedPath(cwd)
    while true {
      if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
        return normalizedPath(dir)
      }
      let parent = (dir as NSString).deletingLastPathComponent
      guard parent != dir else { return nil }
      dir = parent
    }
  }
}
