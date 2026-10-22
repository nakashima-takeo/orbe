#if DEBUG
  import AppKit
  import SwiftUI

  /// ソース管理パネルの gallery / flow の fixture。渡された置き場に、見本（orbe_design の `editor/data.ts`）と同じ形の本物の
  /// git の場を作る——bare の origin に 2 件、upstream を origin/main にしたブランチ `feature/agent-hooks` に未 push の 3 件、
  /// ステージ済みの追加 1 件（EmitBuffer.swift）と変更 3 件（StateHooks.swift・HookRegistry.swift・README.md）。面はソース管理の
  /// パネルを出して窓に載せる。status・グラフ・HEAD の push 済みは git の子プロセス後に届くので、撮る側は `warmUp()` の後
  /// `isReady` を待つ。見本に無い状態（実行中の帯・失敗・同期・公開・変更なし）は、撮る側が本物の git の操作で作る。
  enum ScmFixtures {
    static let branch = "feature/agent-hooks"

    @MainActor final class Scene {
      private let tab: TerminalTab
      /// fixture のリポジトリと bare の origin（置き場の下。消すのは置き場の持ち主）。
      let directory: URL
      let origin: URL
      var group: TabGroup { tab.group }
      var pane: EditorPaneView { group.view.editor }
      var panel: ScmPanel { pane.scm }
      private var warmWindow: NSWindow?

      init(tab: TerminalTab, directory: URL, origin: URL) {
        self.tab = tab
        self.directory = directory
        self.origin = origin
      }

      /// fixture のリポジトリで git を回す。
      var git: FixtureGit { FixtureGit(directory: directory) }

      func cleanup() {
        warmWindow = nil
        pane.removeFromSuperview()
      }

      /// 面を窓に付けてパネルに根のサービスを握らせる（status とグラフの読みが始まる）。
      func warmUp(size: NSSize = NSSize(width: 1100, height: 640)) {
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
          backing: .buffered, defer: false)
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        warmWindow = window
      }

      /// 行・グラフ・HEAD の push 済みが揃った。
      var isReady: Bool {
        panel.changes.staged.count == 1 && panel.changes.changes.count == 3
          && panel.graph?.commits.count == 5 && panel.isHeadPushed == false
          && panel.layout.items.count == 6 && panel.graphLayout.items.count == 6
      }

      /// 撮る view（pane をそのまま載せる）。
      var view: some View { ScmPane(pane: pane) }
    }

    /// リポジトリは `place` の下に作る。git が失敗すれば投げる（→ `FixtureGit`）。
    @MainActor static func scene(queriesRoot: URL, in place: URL) throws -> Scene {
      let base = place.appendingPathComponent("orbe-scm-\(UUID().uuidString)", isDirectory: true)
      let dir = base.appendingPathComponent("repo", isDirectory: true)
      let origin = base.appendingPathComponent("origin.git", isDirectory: true)
      try makeRepository(dir, origin: origin)
      let group = TabGroup(
        key: GitWorktreeRoot.root(of: dir.path),
        editorSurfaces: EditorSurfaces(queriesRoot: queriesRoot, language: { .ja }))
      // 撮る姿が裏の fetch で動かないように止める。
      var settings = SettingsLayer()
      settings[SettingKeys.scmAutoFetch] = false
      group.view.editor.settings = { EffectiveSettings(settings) }
      let tab = TerminalTab(cwd: dir.path, group: group)
      group.view.add(terminal: tab.terminal)
      group.view.show(terminal: tab.terminal)
      group.view.editor.selectPanel(.sourceControl)
      return Scene(tab: tab, directory: dir, origin: origin)
    }

    /// origin に 2 件、`branch` に未 push の 3 件、ステージ済みの追加 1 件と変更 3 件。
    private static func makeRepository(_ dir: URL, origin: URL) throws {
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
      try git(["init", "-q", "--bare", "-b", "main", origin.path])
      try git(["remote", "add", "origin", origin.path])
      let commit = { (subject: String, files: [(String, String)]) in
        for (path, text) in files { try write(path, text) }
        try git(["add", "-A"])
        try git(["commit", "-qm", subject])
      }
      let registry = "final class HookRegistry {\n  var hooks: [String] = []\n"
      let pool = "final class FramePool {\n  var frames: [Int] = []\n"
      try commit(
        "renderer: frame pool を導入",
        [
          ("README.md", "# agent hooks\n\nエージェントの状態の知らせを描画へ渡す。\n"),
          ("src/renderer/FramePool.swift", "final class FramePool {}\n"),
          ("src/agent/StateHooks.swift", EditorDiffFixtures.original),
          ("src/agent/HookRegistry.swift", registry + "}\n"),
        ])
      try commit(
        "Merge pull request #128 from orbe/renderer-pool",
        [("src/renderer/FramePool.swift", pool + "}\n")])
      try git(["push", "-q", "-u", "origin", "main"])
      try git(["switch", "-q", "-c", branch, "--track", "origin/main"])
      try commit(
        "wip: HookRegistry の登録順を整理",
        [("src/agent/HookRegistry.swift", registry + "  var order: [Int] = []\n}\n")])
      try commit(
        "EmitBuffer: tail merge を追加",
        [("src/renderer/FramePool.swift", pool + "  var tail: Int?\n}\n")])
      try commit(
        "StateHooks: emit(coalesce:) を実装",
        [("src/agent/StateHooks.swift", EditorDiffFixtures.original + "\n// coalesce\n")])
      try write("src/agent/EmitBuffer.swift", "final class EmitBuffer {\n  var tail: Int?\n}\n")
      try git(["add", "src/agent/EmitBuffer.swift"])
      try write("src/agent/StateHooks.swift", EditorDiffFixtures.edited + "\n// coalesce\n")
      try write("src/agent/HookRegistry.swift", registry + "  var order: [Int] = [1, 2]\n}\n")
      try write("README.md", "# agent hooks\n\nエージェントの状態の知らせを、畳んでから描画へ渡す。\n")
    }

    private struct ScmPane: NSViewRepresentable {
      let pane: EditorPaneView

      func makeNSView(context: Context) -> EditorPaneView { pane }

      func updateNSView(_ view: EditorPaneView, context: Context) {}
    }
  }
#endif
