import Foundation

/// 1 つのチェックアウト（worktree 含む）に対する型付き git 操作。
/// 全メソッドは背景実行し、completion をメインキューで返す。
final class GitRepo {
  /// worktree のルート（rev-parse --show-toplevel）。
  let root: String
  /// 共有 git dir（refs・objects の在処）。linked worktree でも本体側の同じ場所を指す。
  let commonDir: String
  /// この repo の全操作を通す git 実行基盤。本番は常に `.shared`（排他はインスタンス内で
  /// 閉じるため、同じリポジトリを書く者は全員同じインスタンスを通る必要がある）。
  let runner: GitRunner

  private init(root: String, commonDir: String, runner: GitRunner) {
    self.root = root
    self.commonDir = commonDir
    self.runner = runner
  }

  /// cwd からチェックアウトを解決する。git リポジトリ外なら nil。
  static func open(
    cwd: String, runner: GitRunner = .shared, completion: @escaping (GitRepo?) -> Void
  ) {
    runner.run(["rev-parse", "--show-toplevel", "--git-common-dir"], cwd: cwd) { output in
      guard output.isSuccess else {
        completion(nil)
        return
      }
      let lines = output.stdoutText.split(separator: "\n").map(String.init)
      guard lines.count >= 2 else {
        completion(nil)
        return
      }
      // --git-common-dir は相対で返ることがある（cwd 基準）。絶対へ正規化する。
      let common =
        lines[1].hasPrefix("/")
        ? lines[1]
        : (cwd as NSString).appendingPathComponent(lines[1])
      completion(
        GitRepo(
          root: lines[0], commonDir: (common as NSString).standardizingPath, runner: runner))
    }
  }
}
