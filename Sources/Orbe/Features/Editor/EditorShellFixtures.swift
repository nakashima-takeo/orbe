#if DEBUG
  import AppKit
  import OrbeEditorCore
  import SwiftUI

  /// 骨込みのエディター面の gallery fixture。一時ディレクトリに実在のソース断片（このリポジトリのファイル）を
  /// 写して git リポジトリにし、M / A / U を 1 つずつ作り、文書を 3 つ開く（1 つは未保存）。展示データは作らない。
  /// status は git の子プロセス後に、色とハンクは文書の裏の仕事の後に届くので、撮る側は `warmUp()` の後 `isReady`
  /// を待つ。プロジェクト検索はこのリポジトリを実際に探す（`search` の後 `isSearchDone` を待つ）。
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
      /// 一時リポジトリ（`cleanup()` で消す）。
      let directory: URL
      var pane: EditorPaneView { tab.view.editor }
      private var warmWindow: NSWindow?

      init(tab: TerminalTab, directory: URL) {
        self.tab = tab
        self.directory = directory
      }

      /// 面を窓から外し、一時リポジトリを消す。
      func cleanup() {
        warmWindow = nil
        pane.removeFromSuperview()
        try? FileManager.default.removeItem(at: directory)
      }

      /// 面を窓に付けてツリーに根のサービスを握らせる（status の取り直しが始まる）。撮った後は面が窓から
      /// 外れるので、操作を窓の中で起こしたい flow は操作の前にもう一度呼ぶ（寸法は撮る絵と同じに）。
      func warmUp(size: NSSize = NSSize(width: 1100, height: 640)) {
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
          backing: .buffered, defer: false)
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        warmWindow = window
      }

      /// git バッジが揃い、文書の裏の仕事（色・ハンク）が追いついた。
      var isReady: Bool {
        pane.tree.status?.badge(of: "README.md") == .modified
          && pane.tree.status?.badge(of: "docs/spec/editor/shell.md") == .added
          && tab.editor.documents.allSatisfy { $0.waitUntilCaughtUp(timeout: 0) }
      }

      /// 検索パネルを出し、問いで実際に検索する（開いている文書は保存前の中身、ほかは git grep）。
      func search(_ query: SearchQuery) {
        pane.sidebar.show(.search)
        pane.projectSearch.restore(query)
        pane.projectSearch.search()
      }

      /// 検索が終わった（エラーで始まらなかったときも）。
      var isSearchDone: Bool { !pane.projectSearch.isSearching }

      /// アウトラインを開き、焦点の文書（FileTree.swift）のキャレットを `needle` の頭に置く。結果とカーソル追従が揃うのは
      /// `isOutlineReady` で待つ。
      func showOutline(caretAt needle: String) {
        pane.sidebar.show(.files)
        if !pane.sidebar.isOutlineOpen { pane.sidebar.toggleOutline() }
        guard let document = pane.document else { return }
        let location =
          (document.text.substring(NSRange(location: 0, length: document.text.length))
          as NSString).range(of: needle).location
        document.surface.selectedRange = NSRange(location: location, length: 0)
        document.surface.scrollToCenter(location)
      }

      /// アウトラインの結果が今の版に揃い、キャレットのシンボルが選ばれた。
      var isOutlineReady: Bool {
        guard let document = pane.document, document.wantsOutline else { return false }
        return document.waitUntilCaughtUp(timeout: 0) && pane.outline.selectedRow != nil
      }

      /// 撮る view（pane をそのまま載せる）。
      var view: some View { ShellPane(pane: pane) }
    }

    /// 骨込みの面。gallery が dark / light・広い幅・狭い幅（サイドバーが切り詰まる）を撮る。
    @MainActor static func scene(queriesRoot: URL) throws -> Scene {
      let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbe-editor-shell-\(UUID().uuidString)")
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

      let tab = TerminalTab(
        cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: queriesRoot, language: { .ja }))
      let readmeDocument = try tab.editor.open(readme)
      readmeDocument.surface.responder.perform(Selector(("insertText:")), with: "# ")
      _ = try tab.editor.open(dir.appendingPathComponent("docs/design/tokens.json"))
      _ = try tab.editor.open(
        dir.appendingPathComponent("Sources/Orbe/Features/Editor/FileTree.swift"))
      return Scene(tab: tab, directory: dir)
    }

    private struct ShellPane: NSViewRepresentable {
      let pane: EditorPaneView

      func makeNSView(context: Context) -> EditorPaneView { pane }

      func updateNSView(_ view: EditorPaneView, context: Context) {}
    }
  }
#endif
