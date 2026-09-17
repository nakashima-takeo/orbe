#if DEBUG
  import AppKit
  import SwiftUI

  /// 骨込みのエディター面の gallery fixture。一時ディレクトリに実在のソース断片（このリポジトリのファイル）を
  /// 写して git リポジトリにし、M / A / U を 1 つずつ作り、文書を 3 つ開く（1 つは未保存）。展示データは作らない。
  /// status は git の子プロセス後に届くので、撮る側は `warmUp()` の後 `isReady` を待つ。
  enum EditorShellFixtures {
    /// 写すファイル（リポジトリ相対）。
    private static let copied = [
      "README.md", "Package.swift",
      "Sources/Orbe/Features/Editor/EditorSession.swift",
      "Sources/Orbe/Features/Editor/FileChip.swift",
      "Sources/Orbe/Features/Editor/FileTree.swift",
      "docs/spec/editor/faces.md", "docs/spec/editor/code.md", "docs/design/tokens.json",
    ]

    @MainActor final class Scene {
      let tab: TerminalTab
      var pane: EditorPaneView { tab.view.editor }
      private var warmWindow: NSWindow?

      init(tab: TerminalTab) { self.tab = tab }

      /// 面を窓に付けてツリーに根のサービスを握らせる（status の取り直しが始まる）。
      func warmUp() {
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640), styleMask: [.borderless],
          backing: .buffered, defer: false)
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        warmWindow = window
      }

      /// git バッジが揃った。
      var isReady: Bool {
        pane.tree.status?.badge(of: "README.md") == .modified
          && pane.tree.status?.badge(of: "docs/spec/editor/shell.md") == .added
      }

      /// 撮る view（pane をそのまま載せる）。
      var view: some View { ShellPane(pane: pane) }
    }

    /// 骨込みの面。gallery が dark / light・広い幅・狭い幅を撮る。
    @MainActor static func scene(queriesRoot: URL) throws -> Scene {
      let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbe-editor-shell-\(ProcessInfo.processInfo.processIdentifier)")
      try? FileManager.default.removeItem(at: dir)
      for relative in copied {
        let dest = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
          at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent(relative), to: dest)
      }
      let git = { (args: [String]) in _ = GitRunner.shared.runSync(args, cwd: dir.path) }
      git(["init", "-q", "-b", "main"])
      git(["config", "user.email", "gallery@orbe.dev"])
      git(["config", "user.name", "gallery"])
      git(["add", "-A"])
      git(["commit", "-qm", "gallery"])
      // M: README を書き換える / A: shell.md を足して add / U: notes.txt を未追跡で置く。
      let readme = dir.appendingPathComponent("README.md")
      try (try String(contentsOf: readme, encoding: .utf8) + "\n<!-- gallery -->\n")
        .write(to: readme, atomically: true, encoding: .utf8)
      try "# 面の骨\n".write(
        to: dir.appendingPathComponent("docs/spec/editor/shell.md"), atomically: true,
        encoding: .utf8)
      git(["add", "docs/spec/editor/shell.md"])
      try "todo\n".write(
        to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

      let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: queriesRoot))
      let readmeDocument = try tab.editor.open(readme)
      readmeDocument.surface.responder.perform(Selector(("insertText:")), with: "# ")
      _ = try tab.editor.open(dir.appendingPathComponent("docs/design/tokens.json"))
      _ = try tab.editor.open(
        dir.appendingPathComponent("Sources/Orbe/Features/Editor/FileTree.swift"))
      return Scene(tab: tab)
    }

    private struct ShellPane: NSViewRepresentable {
      let pane: EditorPaneView

      func makeNSView(context: Context) -> EditorPaneView { pane }

      func updateNSView(_ view: EditorPaneView, context: Context) {}
    }
  }
#endif
