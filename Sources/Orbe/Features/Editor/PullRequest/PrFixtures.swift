#if DEBUG
  import AppKit
  import SwiftUI

  /// PR のパネルの gallery / flow の fixture。渡された置き場に本物の git の場を作り、GitHub の代わりに差し替えの出どころが
  /// PR #131 のレビュー用 fixture（pr・commits・files・確認済みファイル・スレッド）を答える——main に 1 件、main から切った
  /// ブランチ `feature/agent-hooks` に 3 件（StateHooks.swift の変更・EmitBuffer.swift の追加・HookRegistry.swift と
  /// README.md の変更）。PR の先頭とコミットの列は手元の HEAD のもの（`Scene.push` で進む）なので、帯は「この worktree で
  /// チェックアウト済み」になる。
  /// レビューのやりとりは `PrFixtureReview` が答える。出どころは面より先に根へ結ぶ（worktree の今の PR は根ごとに 1 つで、最初に
  /// 作った者の出どころを使う）。面は PR のパネルを出して窓に載せる。
  enum PrFixtures {
    static let branch = "feature/agent-hooks"

    /// 出どころの答え方。
    enum Answer {
      /// open の PR #131（標準の fixture）。
      case pullRequest
      /// open の PR #131 だが、PR の先頭のコミットが手元に無い（数えない違いの帯）。
      case notFetched
      /// open の PR #131 で、コミットの題とファイル名に絵文字がある。
      case emoji
      /// open の PR #131 だが、変更ファイルが無い。
      case noFiles
      /// worktree が既定のブランチ（main）に居る（GitHub に問い合わせない）。
      case defaultBranch
      /// open の PR が無い（作成の入口）。`published` はブランチが GitHub に在るか。
      case noPullRequest(published: Bool)
      /// GitHub のどのブランチかが決まらない（gh が無い・認証されていない など）。
      case unavailable(GitHubBranchPullRequestsUnavailable)
      /// 今のブランチの PR の問い合わせが失敗する。
      case failed(GitHubFailure)
    }

    @MainActor final class Scene {
      private let tab: TerminalTab
      let directory: URL
      /// 差し替えの GitHub のレビューのやりとり（書き込みの答え方を変えられる）。
      let review: PrFixtureReview
      /// 差し替えの GitHub が中身の読みと確認済みの書き込みに返す失敗（失敗の札を撮る）。
      let faults: Faults
      var group: TabGroup { tab.group }
      var pane: EditorPaneView { group.view.editor }
      var panel: PrPanel { pane.pullRequest }
      private var warmWindow: NSWindow?

      init(tab: TerminalTab, directory: URL, review: PrFixtureReview, faults: Faults) {
        self.tab = tab
        self.directory = directory
        self.review = review
        self.faults = faults
      }

      func cleanup() {
        warmWindow = nil
        pane.removeFromSuperview()
      }

      /// 面を窓に付けてパネルを見せる（worktree の今の PR を引き始める）。
      func warmUp(size: NSSize = NSSize(width: 1100, height: 640)) {
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
          backing: .buffered, defer: false)
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        warmWindow = window
      }

      /// 答えが出た（PR なら中身と帯まで揃った）。
      var isReady: Bool {
        switch panel.pullRequest.answer {
        case .reading: false
        case .pullRequest(let state):
          state.content != nil && panel.pullRequest.drift != nil && !panel.layout.items.isEmpty
        case .noPullRequest(let creation): creation.published != .checking
        case .unavailable: true
        }
      }

      var view: some View { PrPane(pane: pane) }

      /// PR に push する——`PrFixtureReview.path` の本文を `text` にしたコミットを PR のブランチに足し（差し替えの GitHub の
      /// 先頭も進む）、PR の状態を読み直す。
      func push(_ text: String, subject: String) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(PrFixtureReview.path))
        try FixtureGit(directory: directory)(["commit", "-qam", subject])
        panel.state?.reload()
      }

      /// 変更ファイル `path` の PR の diff を開く。
      func openDiff(_ path: String = PrFixtureReview.path) {
        panel.select(.file(path))
        panel.openSelection(.commit)
      }

      /// 開いた PR の diff の中身・並び・最初の位置・スレッドの絵（本文の測り・印を出せる行）が揃った（表示できない diff は、
      /// 理由が決まった時点で揃った）。
      var isDiffReady: Bool {
        guard let diff = pane.diff else { return false }
        if case .unavailable = diff.content { return true }
        return diff.content == .ready && diff.placement == .placed && !diff.pending
          && diff.comments?.isSettled ?? true
      }
    }

    /// リポジトリは `place` の下に作る。git が失敗すれば投げる（→ `FixtureGit`）。
    @MainActor static func scene(
      _ answer: Answer = .pullRequest, queriesRoot: URL, in place: URL
    ) throws -> Scene {
      let dir = place.appendingPathComponent("orbe-pr-\(UUID().uuidString)", isDirectory: true)
      let base = try makeRepository(dir)
      if case .defaultBranch = answer { try FixtureGit(directory: dir)(["switch", "-q", "main"]) }
      let root = GitWorktreeRoot.root(of: dir.path)
      let review = PrFixtureReview(head: { headCommit(answer, dir: dir) })
      let faults = Faults()
      _ = BranchPullRequest.shared(
        for: root, source: source(answer, base: base, dir: dir, review: review, faults: faults))
      let group = TabGroup(
        key: root, editorSurfaces: EditorSurfaces(queriesRoot: queriesRoot, language: { .ja }))
      var settings = SettingsLayer()
      settings[SettingKeys.scmAutoFetch] = false
      group.view.editor.settings = { EffectiveSettings(settings) }
      let tab = TerminalTab(cwd: dir.path, group: group)
      group.view.add(terminal: tab.terminal)
      group.view.show(terminal: tab.terminal)
      group.editor.selectScreen(.pullRequest)
      return Scene(tab: tab, directory: dir, review: review, faults: faults)
    }

    private static let me = GitHubRepoName(nameWithOwner: "orbe/orbe")

    /// 差し替えの出どころ。確認済みの書き込みは覚えておき、読み直しの答えに載せる（GitHub と同じく、書いた値が次の読み直しに
    /// 出る）。レビューのやりとりは `review` が答える。
    private static func source(
      _ answer: Answer, base: String, dir: URL, review: PrFixtureReview, faults: Faults
    ) -> PullRequestSource {
      let ref = GitHubBranchRef(repo: me, branch: branch)
      let found: GitHubBranchPullRequests.Branch
      switch answer {
      case .pullRequest, .notFetched, .emoji, .noFiles:
        found = .gitHub(
          ref,
          pullRequests: .success([
            GitHubBranchPR(
              number: 131, headRefName: branch, state: "OPEN", baseRefName: "main",
              headRepository: me, url: "https://github.com/orbe/orbe/pull/131")
          ]))
      // 既定のブランチでは問い合わせないので、答えは使われない。
      case .noPullRequest, .defaultBranch: found = .gitHub(ref, pullRequests: .success([]))
      case .unavailable(let reason): found = .unavailable(reason)
      case .failed(let failure): found = .gitHub(ref, pullRequests: .failure(failure))
      }
      let published: Bool
      if case .noPullRequest(let value) = answer { published = value } else { published = true }
      let viewed = Viewed()
      return PullRequestSource(
        branchPullRequests: { _, name, completion in
          completion(
            GitHubBranchPullRequests(
              ledger: GitHubRemoteLedger.Resolved(repositories: ["origin": .github(me)]),
              branches: [name: found]))
        },
        branchExists: { _, completion in completion(.success(published)) },
        content: { _, completion in
          if let failure = faults.content { return completion(.failure(failure)) }
          completion(
            .success(
              content(
                base: base, head: headCommit(answer, dir: dir),
                commits: commits(since: base, in: dir),
                viewed: viewed.paths, answer: answer)))
        },
        setViewed: { value, paths, _, completion in
          if let failure = faults.viewed {
            return completion(GitHubViewedWrite(written: [], failure: failure))
          }
          if value { viewed.paths.formUnion(paths) } else { viewed.paths.subtract(paths) }
          completion(GitHubViewedWrite(written: paths, failure: nil))
        },
        review: { _, completion in
          if let failure = review.readFailure { return completion(.failure(failure)) }
          completion(.success(review.read()))
        },
        writeReview: { write, _, _, _, completion in review.write(write, completion: completion) })
    }

    /// PR の先頭のコミット（`notFetched` なら手元に無いコミット）。
    private static func headCommit(_ answer: Answer, dir: URL) -> String {
      if case .notFetched = answer { return String(repeating: "0", count: 40) }
      return revision("HEAD", in: dir)
    }

    /// 差し替えの GitHub が返す失敗（nil なら通す）。
    final class Faults {
      /// 中身の読みに返す失敗。
      var content: GitHubFailure?
      /// 確認済みの書き込みに返す失敗。
      var viewed: GitHubFailure?
    }

    /// 差し替えの GitHub の確認済みのパス（EmitBuffer.swift と HookRegistry.swift が確認済みから始まる）。
    private final class Viewed {
      var paths: Set<String> = ["src/agent/EmitBuffer.swift", "src/agent/HookRegistry.swift"]
    }

    /// fixture の PR #131 の中身。答え方が `emoji` なら、コミットの題と README の名前に絵文字を混ぜ、`noFiles` なら、変更
    /// ファイルを空にする。
    private static func content(
      base: String, head: String, commits: [GitHubPullRequestContent.Commit], viewed: Set<String>,
      answer: Answer
    ) -> GitHubPullRequestContent {
      let emoji: Bool = if case .emoji = answer { true } else { false }
      let files: [(String, GitHubPullRequestContent.Change)] =
        if case .noFiles = answer {
          []
        } else {
          [
            ("src/agent/StateHooks.swift", .modified), ("src/agent/EmitBuffer.swift", .added),
            ("src/agent/HookRegistry.swift", .modified),
            (emoji ? "📝 README.md" : "README.md", .modified),
          ]
        }
      return GitHubPullRequestContent(
        nodeID: "PR_131", number: 131, title: "StateHooks: emit(coalesce:) で renderer への通知を統一",
        url: "https://github.com/orbe/orbe/pull/131", isDraft: false, state: .open,
        body: "renderer への通知経路を applyEmit から StateHooks.emit(_:coalesce:) に統一する。"
          + "連続する AgentEvent は EmitBuffer の tail で畳み込み、メニューバー側の再描画回数を抑える。",
        author: "claude", baseRefName: "main", headRefName: branch, baseCommit: base,
        headCommit: head, commitCount: commits.count,
        commits: commits.map {
          .init(oid: $0.oid, headline: emoji ? "✨ " + $0.headline + " 🚀" : $0.headline)
        },
        files: files.map { .init(path: $0.0, change: $0.1, isViewed: viewed.contains($0.0)) })
    }

    /// main に 1 件、`branch` に 3 件。main のコミットを返す。
    private static func makeRepository(_ dir: URL) throws -> String {
      let write = { (path: String, text: String) in
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
      }
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let git = FixtureGit(directory: dir)
      try git(["init", "-q", "-b", "main"])
      try git(["config", "user.email", "gallery@orbe.dev"])
      try git(["config", "user.name", "gallery"])
      let commit = { (subject: String, files: [(String, String)]) in
        for (path, text) in files { try write(path, text) }
        try git(["add", "-A"])
        try git(["commit", "-qm", subject])
      }
      let registry = "final class HookRegistry {\n  var hooks: [String] = []\n"
      try commit(
        "agent: hooks を導入",
        [
          ("README.md", "# agent hooks\n\nエージェントの状態の知らせを描画へ渡す。\n"),
          ("src/agent/StateHooks.swift", EditorDiffFixtures.original),
          ("src/agent/HookRegistry.swift", registry + "}\n"),
        ])
      let base = revision("HEAD", in: dir)
      try git(["switch", "-q", "-c", branch])
      try commit(
        "StateHooks: emit(coalesce:) を実装",
        [("src/agent/StateHooks.swift", EditorDiffFixtures.edited)])
      try commit(
        "EmitBuffer: tail merge を追加",
        [("src/agent/EmitBuffer.swift", "final class EmitBuffer {\n  var tail: Int?\n}\n")])
      try commit(
        "StateHooksTests: testCoalesceSkipsUnrelated",
        [
          ("src/agent/HookRegistry.swift", registry + "  var order: [Int] = []\n}\n"),
          ("README.md", "# agent hooks\n\nエージェントの状態の知らせを、畳んでから描画へ渡す。\n"),
        ])
      return base
    }

    /// `base` から手元の HEAD までのコミット（古い順）。
    private static func commits(
      since base: String, in dir: URL
    ) -> [GitHubPullRequestContent.Commit] {
      let output = GitRunner.shared.runSync(
        ["log", "--reverse", "--format=%H%x09%s", "\(base)..HEAD"], cwd: dir.path)
      return (String(bytes: output.stdout, encoding: .utf8) ?? "").split(separator: "\n").map {
        let fields = $0.split(separator: "\t", maxSplits: 1)
        return .init(oid: String(fields[0]), headline: String(fields[1]))
      }
    }

    private static func revision(_ name: String, in dir: URL) -> String {
      let output = GitRunner.shared.runSync(["rev-parse", name], cwd: dir.path)
      return (String(bytes: output.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
    }

    private struct PrPane: NSViewRepresentable {
      let pane: EditorPaneView

      func makeNSView(context: Context) -> EditorPaneView { pane }

      func updateNSView(_ view: EditorPaneView, context: Context) {}
    }
  }
#endif
