import Foundation

/// Dispatch が前回取得した gh 結果をリポジトリ単位で保持する置き場。次に開いたときの先描き
/// （stale-while-revalidate）の元になる。保存先はこの型に閉じており、ディスク永続へ移す場合も
/// ここの中だけを差し替える。
/// キーは `GitRepo.commonDir`（worktree 間で共有される唯一の識別子。issue/PR はリポジトリ全体の話）。
/// メインスレッド専用（`DispatchDataProvider` の全メソッドと `GitHubCLI` の completion がメインで返る
/// 契約に乗るため、ロックは張らない）。
final class DispatchGitHubCache {
  static let shared = DispatchGitHubCache()

  /// どちらも `nil` = 未取得（`[]` は 0 件）。GitHubCLI の境界と同じ区別をここでも保つ。
  struct Entry {
    var issues: [GitHubIssue]?
    var pullRequests: [GitHubPullRequest]?
  }

  private var entries: [String: Entry] = [:]

  func entry(for key: String) -> Entry? { entries[key] }

  /// issues と PR は独立に到着し独立に失敗しうるので setter を分ける（片方の失敗が他方を巻き込まない）。
  func setIssues(_ issues: [GitHubIssue], for key: String) {
    entries[key, default: Entry()].issues = issues
  }

  func setPullRequests(_ pullRequests: [GitHubPullRequest], for key: String) {
    entries[key, default: Entry()].pullRequests = pullRequests
  }
}
