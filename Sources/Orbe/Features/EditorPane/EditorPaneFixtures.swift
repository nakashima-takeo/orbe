#if DEBUG
  import Foundation
  import SwiftUI

  /// EditorPane の story/snapshot 用フィクスチャ。**本物の FileChange/FileDiff/Commit を
  /// 本物の EditorPaneRoot に流す**ための燃料（stub で塗りつぶさない鉄則）。
  /// 文言は EditorPane の設計見本と同等。件数の桁だけは
  /// 実在する小さな diff から計算されるため見本の飾り数字（+812 等）とは一致しない。
  enum EditorPaneFixtures {

    // MARK: - パス・内容

    private static let swiftPath = "src/agent/StateHooks.swift"
    private static let mdPath = "docs/README.md"

    private static let treePaths = [
      swiftPath,
      "src/agent/EmitBuffer.swift",
      "src/agent/HookRegistry.swift",
      "src/renderer/Renderer.swift",
      "src/renderer/EmitQueue.swift",
      mdPath,
      "docs/architecture.md",
      "docs/hooks.md",
      "core/clock.swift",
      "tests/hooks_test.swift",
      ".orbe.json",
      "Package.swift",
    ]

    /// 見本 SWIFT_FILE_LINES（41〜54行）を実ファイル内容として持つ（前 40 行は充填）。
    private static var swiftContent: String {
      var lines = (1...40).map { "// filler line \($0)" }
      lines += [
        "import Dispatch",
        "final class StateHooks {",
        "  private var observers: [StateObserver] = []",
        "  private let queue = DispatchQueue(label: \"orbe.hooks\")",
        "  private var pending: [StateEvent] = []",
        "",
        "  func emit(_ e: StateEvent, coalesce: Bool = true) {",
        "    guard coalesce else { return dispatch(e) }",
        "    queue.async { [weak self] in",
        "      self?.pending.append(e)",
        "    }",
        "  }",
        "",
        "  private func dispatch(_ e: StateEvent) {",
      ]
      return lines.joined(separator: "\n") + "\n"
    }

    /// 見本 MD_SOURCE_LINES / MdPreviewBody と同内容の README。
    private static let mdContent = """
      # orbe

      エージェントセッションを worktree 単位で束ねるターミナル。タブ＝フォルダ、ファイルは常に1枚。

      ## Agent hooks

      - `emit` はステートイベントをレンダラへ通知します
      - フックは `HookRegistry` に登録します
      - バッチ処理はデフォルトで有効です

      | フック | 契機 | 既定 |
      | --- | --- | --- |
      | `emit` | 状態変化 | 有効 |
      | `flush` | セッション終了 | `off` |

      ```sh
      $ orbe run --agent claude
      ```
      """

    // MARK: - 差分

    /// staged hunk（見本 SWIFT_HUNKS[0]: @@ −42,6 +42,10 @@ final class StateHooks）。
    private static var swiftStagedDiff: FileDiff {
      FileDiff(
        oldPath: swiftPath, newPath: swiftPath, isBinary: false,
        oldMode: "100644", newMode: "100644", similarity: nil,
        hunks: [
          Hunk(
            oldStart: 42, oldCount: 6, newStart: 42, newCount: 10,
            sectionHeading: "final class StateHooks",
            lines: [
              DiffLine(kind: .context, text: "final class StateHooks {", oldLine: 42, newLine: 42),
              DiffLine(
                kind: .context, text: "  private var observers: [StateObserver] = []",
                oldLine: 43, newLine: 43),
              DiffLine(
                kind: .added, text: "  private let queue = DispatchQueue(label: \"orbe.hooks\")",
                newLine: 44),
              DiffLine(kind: .added, text: "  private var pending: [StateEvent] = []", newLine: 45),
              DiffLine(kind: .removed, text: "  func emit(_ event: StateEvent) {", oldLine: 44),
              DiffLine(
                kind: .added, text: "  func emit(_ e: StateEvent, coalesce: Bool = true) {",
                newLine: 47),
              DiffLine(
                kind: .added, text: "    guard coalesce else { return dispatch(e) }", newLine: 48),
              DiffLine(
                kind: .context, text: "    queue.async { [weak self] in", oldLine: 45, newLine: 49),
              DiffLine(
                kind: .context, text: "      self?.pending.append(e)", oldLine: 46, newLine: 50),
            ])
        ])
    }

    /// unstaged hunk（見本 SWIFT_HUNKS[1]: @@ −88,4 +92,12 @@ func flush()。折りたたみで +12 −2）。
    private static var swiftUnstagedDiff: FileDiff {
      let removed = (1...2).map { i in
        DiffLine(kind: .removed, text: "    legacyFlush(step: \(i))", oldLine: 88 + i)
      }
      let added = (1...12).map { i in
        DiffLine(kind: .added, text: "    flushBatch(chunk: \(i))", newLine: 92 + i)
      }
      return FileDiff(
        oldPath: swiftPath, newPath: swiftPath, isBinary: false,
        oldMode: "100644", newMode: "100644", similarity: nil,
        hunks: [
          Hunk(
            oldStart: 88, oldCount: 4, newStart: 92, newCount: 12,
            sectionHeading: "func flush()",
            lines: [
              DiffLine(kind: .context, text: "  func flush() {", oldLine: 88, newLine: 92)
            ] + removed + added)
        ])
    }

    /// md の unstaged diff（見本 MD_HUNKS 相当: emit 行を mod・バッチ行とコードブロックを add でマーク）。
    private static var mdUnstagedDiff: FileDiff {
      FileDiff(
        oldPath: mdPath, newPath: mdPath, isBinary: false,
        oldMode: "100644", newMode: "100644", similarity: nil,
        hunks: [
          Hunk(
            oldStart: 7, oldCount: 3, newStart: 7, newCount: 7,
            sectionHeading: "Agent hooks",
            lines: [
              DiffLine(kind: .removed, text: "- emit is delivered synchronously.", oldLine: 7),
              DiffLine(
                kind: .added, text: "- `emit` notifies the renderer of state events", newLine: 7),
              DiffLine(
                kind: .context, text: "- hooks register with `HookRegistry`", oldLine: 8, newLine: 8
              ),
              DiffLine(kind: .added, text: "- batching is enabled by default", newLine: 9),
              DiffLine(kind: .context, text: "", oldLine: 9, newLine: 10),
              DiffLine(kind: .added, text: "```sh", newLine: 11),
              DiffLine(kind: .added, text: "$ orbe run --agent claude", newLine: 12),
              DiffLine(kind: .added, text: "```", newLine: 13),
            ])
        ])
    }

    /// 小さな追加/変更 diff（脇役ファイル用）。
    private static func smallDiff(path: String, new: Bool, add: Int, del: Int = 0) -> FileDiff {
      let removed = (0..<del).map { i in
        DiffLine(kind: .removed, text: "old line \(i)", oldLine: 1 + i)
      }
      let added = (0..<add).map { i in
        DiffLine(kind: .added, text: "new line \(i)", newLine: 1 + i)
      }
      return FileDiff(
        oldPath: new ? nil : path, newPath: path, isBinary: false,
        oldMode: new ? nil : "100644", newMode: "100644", similarity: nil,
        hunks: [
          Hunk(
            oldStart: new ? 0 : 1, oldCount: del, newStart: 1, newCount: add,
            sectionHeading: "", lines: removed + added)
        ])
    }

    // MARK: - status（変更レールのグルーピング: docs / src/agent / src/renderer / core / tests）

    private static var files: [FileChange] {
      [
        FileChange(path: mdPath, oldPath: nil, staged: nil, unstaged: .modified),
        FileChange(path: "docs/hooks.md", oldPath: nil, staged: .added, unstaged: nil),
        FileChange(path: swiftPath, oldPath: nil, staged: .modified, unstaged: .modified),
        FileChange(path: "src/agent/EmitBuffer.swift", oldPath: nil, staged: nil, unstaged: .added),
        FileChange(
          path: "src/agent/HookRegistry.swift", oldPath: nil, staged: nil, unstaged: .modified),
        FileChange(
          path: "src/renderer/Renderer.swift", oldPath: nil, staged: nil, unstaged: .modified),
        FileChange(path: "core/clock.swift", oldPath: nil, staged: nil, unstaged: .modified),
        FileChange(path: "tests/hooks_test.swift", oldPath: nil, staged: .modified, unstaged: nil),
      ]
    }

    private static var unstagedDiffs: [String: FileDiff] {
      [
        swiftPath: swiftUnstagedDiff,
        mdPath: mdUnstagedDiff,
        "src/agent/EmitBuffer.swift": smallDiff(
          path: "src/agent/EmitBuffer.swift", new: true, add: 6),
        "src/agent/HookRegistry.swift": smallDiff(
          path: "src/agent/HookRegistry.swift", new: false, add: 4, del: 1),
        "src/renderer/Renderer.swift": smallDiff(
          path: "src/renderer/Renderer.swift", new: false, add: 8, del: 3),
        "core/clock.swift": smallDiff(path: "core/clock.swift", new: false, add: 3, del: 2),
      ]
    }

    private static var stagedDiffs: [String: FileDiff] {
      [
        swiftPath: swiftStagedDiff,
        "docs/hooks.md": smallDiff(path: "docs/hooks.md", new: true, add: 9),
        "tests/hooks_test.swift": smallDiff(
          path: "tests/hooks_test.swift", new: false, add: 5, del: 1),
      ]
    }

    // MARK: - 履歴（見本 HistoryRail と同トポロジ: feature が main から分岐して戻る）

    private static let oids = (
      head: "a3f21c9000000000000000000000000000000001",
      registry: "8c04d2e000000000000000000000000000000002",
      scaffold: "51b9aa0000000000000000000000000000000003",
      merge: "f04e1d2000000000000000000000000000000004",
      originMain: "9d21c77000000000000000000000000000000005",
      branchPoint: "2b11c03000000000000000000000000000000006"
    )

    private static func commits(now: Date) -> [Commit] {
      [
        Commit(
          oid: oids.head, shortOid: "a3f21c9", author: "agent",
          date: now.addingTimeInterval(-12 * 60), parents: [oids.registry],
          refs: ["HEAD -> feature/agent-hooks"], subject: "Migrate fully to the emit API"),
        Commit(
          oid: oids.registry, shortOid: "8c04d2e", author: "agent",
          date: now.addingTimeInterval(-60 * 60), parents: [oids.scaffold], refs: [],
          subject: "Add hook registry"),
        Commit(
          oid: oids.scaffold, shortOid: "51b9aa0", author: "you",
          date: now.addingTimeInterval(-2 * 60 * 60), parents: [oids.merge], refs: [],
          subject: "scaffold hooks"),
        Commit(
          oid: oids.merge, shortOid: "f04e1d2", author: "you",
          date: now.addingTimeInterval(-26 * 60 * 60),
          parents: [oids.branchPoint, oids.originMain], refs: [], subject: "merge main"),
        Commit(
          oid: oids.originMain, shortOid: "9d21c77", author: "you",
          date: now.addingTimeInterval(-3 * 24 * 60 * 60), parents: [oids.branchPoint],
          refs: ["origin/main", "tag: v0.9.0"], subject: "v0.9.0"),
        Commit(
          oid: oids.branchPoint, shortOid: "2b11c03", author: "you",
          date: now.addingTimeInterval(-4 * 24 * 60 * 60), parents: [], refs: [],
          subject: "core: clock utils"),
      ]
    }

    // MARK: - モデル

    /// 共通の土台（ブランチ・status・diff・ツリー・履歴・内容）。
    private static func baseModel() -> EditorPaneModel {
      let model = EditorPaneModel()
      model.ui.paneOpen = true  // プレビューは本体パネルを開いた状態で見せる。
      model.branch = "feature/agent-hooks"
      model.upstream = "origin/main"
      model.ahead = 3
      model.behind = 0
      model.files = files
      model.treeNodes = FileTree.build(paths: treePaths)
      model.unstagedDiffs = unstagedDiffs
      model.stagedDiffs = stagedDiffs
      let now = Date()
      model.commits = commits(now: now)
      model.unpushedOids = [oids.head, oids.registry, oids.scaffold]
      model.historyExhausted = true
      let contents = [
        swiftPath: swiftContent,
        mdPath: mdContent + "\n",
      ]
      model.readFile = { contents[$0] }
      return model
    }

    /// ツリーツール＋swift 全文（行番号・変更行ガターマーク・非md=誘導文）。
    static func treeModel() -> EditorPaneModel {
      let model = baseModel()
      model.ui.tool = .tree
      model.ui.selectedPath = swiftPath
      model.ui.viewMode = .file
      // 見本の開閉状態: src/agent/docs 開・renderer/core/tests 閉。
      model.ui.treeFolderOpen = [
        "src": true, "src/agent": true, "docs": true,
        "src/renderer": false, "core": false, "tests": false,
      ]
      return model
    }

    /// ツリーツール＋md ソース（変更行マーク付き）。
    static func mdSourceModel() -> EditorPaneModel {
      let model = treeModel()
      model.ui.selectedPath = mdPath
      model.ui.viewMode = .source
      return model
    }

    /// ツリーツール＋md プレビュー（MarkdownView 流用・EditorPane スタイル）。
    static func mdPreviewModel() -> EditorPaneModel {
      let model = treeModel()
      model.ui.selectedPath = mdPath
      model.ui.viewMode = .preview
      return model
    }

    /// git 変更サブタブ＋diff 統合表示（staged hunk＋折りたたみ unstaged hunk）＋CommitBar。
    static func changesDiffModel() -> EditorPaneModel {
      let model = baseModel()
      model.ui.tool = .git
      model.ui.gitTab = .changes
      model.ui.selectedPath = swiftPath
      model.ui.viewMode = .diff
      model.ui.collapsedHunks = ["U:\(swiftPath)@92"]
      model.ui.commitDraft = "refactor(renderer): migrate fully to the emit API"
      return model
    }

    /// git 変更サブタブ＋コミット成功の最小表示（PaneBannerStrip）。
    static func changesBannerModel() -> EditorPaneModel {
      let model = changesDiffModel()
      model.banner = .success("✓ Committed (pre-commit passed)")
      return model
    }

    /// git 履歴サブタブ＋CommitDetail（HEAD 選択・詳細ロード済み・listWidth 240）。
    static func historyModel() -> EditorPaneModel {
      let model = baseModel()
      model.ui.tool = .git
      model.ui.gitTab = .history
      model.ui.selectedCommit = .commit(oids.head)
      model.commitDetail = CommitDetailData(
        commit: model.commits[0],
        files: [
          swiftStagedDiff,
          smallDiff(path: "src/agent/EmitBuffer.swift", new: true, add: 12),
          smallDiff(path: "src/renderer/Renderer.swift", new: false, add: 9, del: 4),
        ])
      return model
    }

    /// ブラウザツール（dev サーバー未検出＝空状態「dev サーバー未起動」・ToolRail のブラウザボタンは減光）。
    static func browserModel() -> EditorPaneModel {
      let model = baseModel()
      model.ui.tool = .browser
      return model
    }
  }

  #Preview("EditorPane — Tree") {
    EditorPaneRoot(model: EditorPaneFixtures.treeModel())
      .frame(width: 376, height: 440)
      .background(Color.theme.bgBase)
  }

  #Preview("EditorPane — md preview") {
    EditorPaneRoot(model: EditorPaneFixtures.mdPreviewModel())
      .frame(width: 376, height: 440)
      .background(Color.theme.bgBase)
  }

  #Preview("EditorPane — git changes diff") {
    EditorPaneRoot(model: EditorPaneFixtures.changesDiffModel())
      .frame(width: 376, height: 440)
      .background(Color.theme.bgBase)
  }

  #Preview("EditorPane — git history") {
    EditorPaneRoot(model: EditorPaneFixtures.historyModel())
      .frame(width: 376, height: 440)
      .background(Color.theme.bgBase)
  }

  #Preview("EditorPane — Browser") {
    EditorPaneRoot(model: EditorPaneFixtures.browserModel())
      .frame(width: 376, height: 440)
      .background(Color.theme.bgBase)
  }
#endif
