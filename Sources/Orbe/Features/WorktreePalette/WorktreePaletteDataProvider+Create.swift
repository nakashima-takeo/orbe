import Foundation

/// Enter の実行先の解決（`WorktreePaletteDataProvider` の分冊）。行種別から対象ディレクトリを決め、
/// 無ければ worktree を作る——作成は追加のみで、呼び出し元のチェックアウトには触らない。
extension WorktreePaletteDataProvider {
  /// 解決結果。`ready` は起動先パス、`failed` はエラーメッセージ（palette に表示）。
  enum DirectoryResolution {
    case ready(String)
    case failed(String)
  }

  /// Enter の解決の結末。解決したか、新しいブランチを作ったか、作らずにユーザーへ問うか。
  enum PrepareOutcome {
    case resolved(DirectoryResolution)
    /// 新しいブランチを切って worktree を作った。base は実際に使ったベースの名前（既定ブランチの意図
    /// なら解決後の名前）。
    case created(path: String, base: String)
    /// Local branch が upstream より遅れていて fast-forward できる。worktree は作っていない——
    /// 最新化して作るか、そのまま作るかを選択画面が問う。画面はブランチの事実（遅れとブランチの
    /// 相対日時）だけで組めるので、それを運ぶ。
    case staleBranch(WorktreePaletteBranchSync, relativeDate: String)
  }

  /// 行き先に応じて対象ディレクトリを解決する（必要なら worktree を新規作成する）。
  /// 作成は追加のみ（現在の作業ツリーは不可侵）。失敗は Git 層の `GitFailure` を UI 言語へ写して返す。
  /// 既存ディレクトリを返すだけの経路はリポジトリを要さない——非 git（`repo == nil`）を畳むのは
  /// リポジトリが要る作成経路（`createWorktree`）の責務。
  func prepareDirectory(
    for destination: WorktreePaletteDestination,
    completion: @escaping (PrepareOutcome) -> Void
  ) {
    let resolved = { completion(.resolved($0)) }
    switch destination {
    case .directory(let path):
      resolved(.ready(path))

    case .localBranch(let name):
      resolveLocalBranch(name, completion: completion)

    case .remoteBranch(let name, let existing):
      if let existing {
        resolved(.ready(existing))
        return
      }
      let local = WorktreePaletteSectionBuilder.localName(fromRemote: name)
      createWorktree(
        at: worktreeDir(forBranch: local), base: .ref(name),
        newBranch: GitNewBranch(name: local, tracksBase: true)
      ) { resolution, _ in resolved(resolution) }

    case .newBranch(let name, let base):
      // upstream を付けない: ベースを upstream に持つと `git push` がベースへ向かって拒否され、
      // `push.autoSetupRemote` も（upstream が既にあるため）発動しない。upstream 無しなら git が正しい
      // `--set-upstream` へ導く。
      createWorktree(
        at: worktreeDir(forBranch: name), base: base,
        newBranch: GitNewBranch(name: name, tracksBase: false)
      ) { resolution, baseName in
        switch resolution {
        case .ready(let path): completion(.created(path: path, base: baseName))
        case .failed: resolved(resolution)
        }
      }
    }
  }

  /// Local branch 行の Enter。**信頼する remote を追跡する行は fetch の着地を待ってから判定する**
  /// ——着地前の値で決めると、提示直後に速く押した人だけが最新化を選べない。着地後の値で
  /// fast-forward できる遅れなら作らずに問い、それ以外（同期済み・分岐・↑ だけ・`[gone]`）は今どおり作る。
  /// upstream が無い／信頼しない remote の行は fetch で動く値に依存しないので待たない。
  private func resolveLocalBranch(
    _ name: String, completion: @escaping (PrepareOutcome) -> Void
  ) {
    let create = { self.createLocalBranchWorktree(name: name) { completion(.resolved($0)) } }
    guard let branch = localBranches.first(where: { $0.name == name }),
      WorktreePaletteBranchSync.tracksTrustedRemote(branch)
    else {
      create()
      return
    }
    remoteFetchLanding.notify(queue: .main) {
      let landed = self.localBranches.first { $0.name == name }
      if let landed, let sync = WorktreePaletteBranchSync(landed), sync.isFastForwardable {
        completion(.staleBranch(sync, relativeDate: landed.relativeDate))
      } else {
        create()
      }
    }
  }

  /// 既存のローカルブランチをそのまま checkout した worktree を作る。同期の検査を通らない——
  /// 最新化画面の「そのまま作成」がこれで、検査を通すと再び「遅れている」が返って堂々巡りになる。
  func createLocalBranchWorktree(
    name: String, completion: @escaping (DirectoryResolution) -> Void
  ) {
    createWorktree(at: worktreeDir(forBranch: name), base: .ref(name), newBranch: nil) { r, _ in
      completion(r)
    }
  }

  /// 最新化画面の「最新化して作成」。fetch → fast-forward → 列挙の引き直し → 作成、を直列に進める
  /// 手順の唯一の定義。`creating` は作成が始まった時点（最新化が済んだ時点）で 1 度呼ぶ。
  /// 引き直しを挟むのは、ff が済んだ一覧の行が同期ピルを失った姿で戻るため（成功後に作成が落ちたとき）。
  func refreshAndCreate(
    _ sync: WorktreePaletteBranchSync, creating: @escaping () -> Void,
    completion: @escaping (Result<DirectoryResolution, GitRefreshFailure>) -> Void
  ) {
    guard let repo else {
      createLocalBranchWorktree(name: sync.name) { completion(.success($0)) }
      return
    }
    repo.fastForwardBranch(name: sync.name, upstream: sync.upstream) { failure in
      if let failure {
        completion(.failure(failure))
        return
      }
      self.loadGit(repo, classifying: false) {
        creating()
        self.createLocalBranchWorktree(name: sync.name) { completion(.success($0)) }
      }
    }
  }

  /// ベースの今の名前（既定ブランチの意図は今の解決値）。
  private func name(of base: WorktreeBase) -> String {
    switch base {
    case .ref(let name): name
    case .defaultBranch: defaultBranchName
    }
  }

  /// 解決済みパスへ worktree を作る。作成先が作業ツリー内に落ちるときだけ、**作成できた後で**共有
  /// exclude へ除外を冪等に入れる（プリセット由来かカスタム由来かを問わず、解決済みパスだけで判定する）。
  /// 除外の成否は作成に影響しない。
  ///
  /// **新しいブランチを切るなら、そのベースは fetch 後の状態であるべき**——提示時の `fetch --prune` が
  /// まだ走っているなら着地を待ってから撃つ。判定を呼び出し側ではなくここに置くのは、作成経路が
  /// 増えたときの包み忘れを構造で塞ぐため。既存ブランチを checkout するだけの経路は fetch で動く ref を
  /// ベースに取らないので待たない。
  /// completion の 2 つ目は、作成に使ったベースの名前（撃った時点で解決した値）。
  private func createWorktree(
    at path: String, base: WorktreeBase, newBranch: GitNewBranch?,
    completion: @escaping (DirectoryResolution, String) -> Void
  ) {
    guard let repo else {
      completion(.failed(localization.string(.worktreePaletteErrNotGitRepo)), name(of: base))
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
      let baseName = self.name(of: base)
      repo.addWorktree(path: path, base: baseName, newBranch: newBranch) { failure in
        if let failure {
          switch failure {
          case .timedOut: completion(.failed(localization.string(.gitTimedOut)), baseName)
          case .reason(let reason): completion(.failed(reason), baseName)
          }
          return
        }
        // 書くのは作成できたときだけ（失敗した作成の除外を残さない）。この時点では対象が実在するので
        // `check-ignore` の「既にユーザーが塞いでいるか」判定も正しく効く。
        repo.applyWorktreeExclude(entry, worktreeRoot: root) { completion(.ready(path), baseName) }
      }
    }
    guard newBranch != nil else {
      add()
      return
    }
    // 着地の成否は問わない——fetch が落ちたなら手元の `refs/remotes/origin/*` が最良で、worktree パレットの
    // 他経路（分類の引き直し）と同じ「失敗は据え置き」に揃える。
    remoteFetchLanding.notify(queue: .main, execute: add)
  }

  // MARK: - パス導出

  /// テンプレート解決の base。`{repo_path}`/`{parent}`/`{repo}` の導出元であり、repo 内解決の判定
  /// （除外の自動化）が使う作業ツリー root でもある。作成行の衝突の規則（`newBranchRules`）も同じ値で解く。
  var worktreeBase: String { mainWorktree ?? repo?.root ?? cwd }

  /// 実効テンプレート（設定 `worktree-dir`）から作成先を解決する。置換・`~` 展開・standardize は
  /// `WorktreePathTemplate` に一本化する。
  private func worktreeDir(forBranch name: String) -> String {
    WorktreePathTemplate.resolve(
      template: worktreeTemplate, repoPath: worktreeBase,
      slug: WorktreePathTemplate.slug(forBranch: name))
  }
}
