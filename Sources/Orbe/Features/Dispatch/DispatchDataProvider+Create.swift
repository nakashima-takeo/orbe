import Foundation

/// Enter の実行先の解決（`DispatchDataProvider` の分冊）。行種別から対象ディレクトリを決め、
/// 無ければ worktree を作る——作成は追加のみで、呼び出し元のチェックアウトには触らない。
extension DispatchDataProvider {
  /// 解決結果。`ready` は起動先パス、`failed` はエラーメッセージ（palette に表示）。
  enum DirectoryResolution {
    case ready(String)
    case failed(String)
  }

  /// 行種別に応じて対象ディレクトリを解決する（必要なら worktree を新規作成する）。
  /// 作成は追加のみ（現在の作業ツリーは不可侵）。失敗は Git 層の `GitFailure` を UI 言語へ写して返す。
  /// 既存ディレクトリを返すだけの経路はリポジトリを要さない——非 git（`repo == nil`）を畳むのは
  /// リポジトリが要る作成経路（`createWorktree`）の責務。
  func prepareDirectory(
    for action: DispatchAction, completion: @escaping (DirectoryResolution) -> Void
  ) {
    switch action {
    case .worktree(let path):
      completion(.ready(path))

    case .localBranch(let name, let existing):
      if let existing {
        completion(.ready(existing))
        return
      }
      createWorktree(
        at: worktreeDir(forSlug: slug(name)), base: name, newBranch: nil, completion: completion)

    case .remoteBranch(let name, let existing):
      if let existing {
        completion(.ready(existing))
        return
      }
      let local = localName(fromRemote: name)
      createWorktree(
        at: worktreeDir(forSlug: slug(local)), base: name,
        newBranch: GitNewBranch(name: local, tracksBase: true), completion: completion)

    case .issue(let number, let existing, let branchExists):
      if let existing {
        completion(.ready(existing))
        return
      }
      let branch = "issue/\(number)"
      let path = worktreeDir(forSlug: slug(branch))
      if branchExists {
        // 既存ブランチから worktree 追加（-b を外す）＝ git worktree add <path> issue/<n>。
        createWorktree(at: path, base: branch, newBranch: nil, completion: completion)
      } else {
        // 新規: git worktree add -b issue/<n> --no-track <path> <default>。既定ブランチを upstream に
        // 持つと `git push` が既定ブランチへ向かって拒否され、`push.autoSetupRemote` も（upstream が
        // 既にあるため）発動しない。upstream 無しなら git が正しい `--set-upstream` へ導く。
        createWorktree(
          at: path, base: defaultBranchName,
          newBranch: GitNewBranch(name: branch, tracksBase: false), completion: completion)
      }

    case .pullRequest(let number, let headRef, let isCrossRepo, let existing):
      if let existing {
        completion(.ready(existing))
        return
      }
      // fork（cross-repo）PR は head ref がローカルに無く、現 dir を破壊せず隔離 worktree に持ち込む
      // 汎用手段が無い。安全側に倒し、worktree 化はせず「ブラウザで開く」へ誘導する（残った前提の決着）。
      if isCrossRepo {
        completion(.failed(localization.format(.dispatchErrForkPR, number)))
        return
      }
      createWorktree(
        at: worktreeDir(forSlug: slug(headRef)), base: "origin/\(headRef)",
        newBranch: GitNewBranch(name: headRef, tracksBase: true), completion: completion)

    case .clean:
      // clean 行はディレクトリを持たない。決定は `DispatchPaletteModel.activate` がパレット内で畳むため
      // ここへは届かない——網羅 switch は、行種別が増えたときの分類漏れを検出する役だけを果たす。
      assertionFailure("clean 行は prepareDirectory を通らない")
    }
  }

  /// 解決済みパスへ worktree を作る。作成先が作業ツリー内に落ちるときだけ、**作成できた後で**共有
  /// exclude へ除外を冪等に入れる（プリセット由来かカスタム由来かを問わず、解決済みパスだけで判定する）。
  /// 除外の成否は作成に影響しない。
  ///
  /// **新しいブランチを切るなら、そのベースは fetch 後の状態であるべき**——提示時の `fetch --prune` が
  /// まだ走っているなら着地を待ってから撃つ。判定を呼び出し側ではなくここに置くのは、作成経路が
  /// 増えたときの包み忘れを構造で塞ぐため。既存ブランチを checkout するだけの経路はベースを持たない
  /// ので待たない。
  private func createWorktree(
    at path: String, base: String, newBranch: GitNewBranch?,
    completion: @escaping (DirectoryResolution) -> Void
  ) {
    guard let repo else {
      completion(.failed(localization.string(.dispatchErrNotGitRepo)))
      return
    }
    // 除外の対象は作成の**前**に決める——作成後は親が実在してしまい、その親を容れ物として Orbe が
    // 作ったのか、ユーザーの既存ディレクトリなのかを判別できなくなる。
    let root = worktreeBase
    let entry = GitWorktreeExclude.entry(
      worktreePath: path, worktreeRoot: root,
      parentIsNew: !FileManager.default.fileExists(
        atPath: (path as NSString).deletingLastPathComponent))
    let localization = self.localization
    let add = {
      repo.addWorktree(path: path, base: base, newBranch: newBranch) { failure in
        if let failure {
          switch failure {
          case .timedOut: completion(.failed(localization.string(.gitTimedOut)))
          case .reason(let reason): completion(.failed(reason))
          }
          return
        }
        // 書くのは作成できたときだけ（失敗した作成の除外を残さない）。この時点では対象が実在するので
        // `check-ignore` の「既にユーザーが塞いでいるか」判定も正しく効く。
        repo.applyWorktreeExclude(entry, worktreeRoot: root) { completion(.ready(path)) }
      }
    }
    guard newBranch != nil else {
      add()
      return
    }
    // 着地の成否は問わない——fetch が落ちたなら手元の `refs/remotes/origin/*` が最良で、dispatch の
    // 他経路（分類の引き直し）と同じ「失敗は据え置き」に揃える。
    remoteFetchLanding.notify(queue: .main, execute: add)
  }

  /// issue/PR／PR に紐づく worktree・branch をブラウザで開く（fire-and-forget）。
  /// `linkedPRNumber` を最優先で見ることで「PR に紐づく行は PR を開く」を構造化する。
  func openWeb(for item: DispatchItem) {
    guard let repo else { return }
    if let number = item.linkedPRNumber {
      GitHubCLI.shared.openPRWeb(number: number, cwd: repo.root)
      return
    }
    switch item.action {
    case .issue(let number, _, _):
      GitHubCLI.shared.openIssueWeb(number: number, cwd: repo.root)
    case .pullRequest(let number, _, _, _):
      GitHubCLI.shared.openPRWeb(number: number, cwd: repo.root)
    default:
      break
    }
  }

  // MARK: - パス導出

  /// テンプレート解決の base。`{repo_path}`/`{parent}`/`{repo}` の導出元であり、repo 内解決の判定
  /// （除外の自動化）が使う作業ツリー root でもある。
  private var worktreeBase: String { mainWorktree ?? repo?.root ?? cwd }

  /// 実効テンプレート（設定 `worktree-dir`）から作成先を解決する。置換・`~` 展開・standardize は
  /// `WorktreePathTemplate` に一本化する。
  private func worktreeDir(forSlug slug: String) -> String {
    WorktreePathTemplate.resolve(template: worktreeTemplate, repoPath: worktreeBase, slug: slug)
  }

  private func slug(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "-")
  }

  private func localName(fromRemote name: String) -> String {
    let parts = name.split(separator: "/", maxSplits: 1)
    return parts.count == 2 ? String(parts[1]) : name
  }
}
