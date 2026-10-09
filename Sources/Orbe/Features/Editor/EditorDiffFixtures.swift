#if DEBUG
  import AppKit
  import OrbeEditorCore
  import SwiftUI

  /// diff のタブの flow fixture。凍結したコードの断片を渡された置き場の git リポジトリにコミットし、作業ツリー・index で
  /// 見本（orbe_design の `diffLines`）と同じ形の書き換え（同じ 2 行・削除 2 行と追加 8 行の区間・同じ 1 行・追加 1 行・
  /// 同じ 1 行）と、削除の多い区間・ステージした rename・ステージしたバイナリを起こす。開くのは撮る側（`open_diff` と同じ
  /// セッションの口）。版の本文は git の子プロセス後に、色とハンクは裏の仕事の後に届くので、撮る側は diff の中身が揃うのを
  /// 待つ。
  enum EditorDiffFixtures {
    /// コミットする断片（構文色の 8 つの役割——鍵語・制御・型・関数・文字列・コメント・変数・約物——が削除と追加の行に
    /// 乗る）。
    static let original = """
      import Foundation

      /// エージェントの状態の知らせを溜めて、描画へまとめて渡す。
      final class HookBuffer {
        private var buffer = EventRing(capacity: 64)
        private let renderer: Renderer
        private let queue = DispatchQueue(label: "orbe.hooks")

        func applyEmit(_ event: AgentEvent) {
          buffer.append(event)
          renderer.notify(.hooksDidEmit)
        }

        /// 溜めた知らせの数（描画の負荷の目安）。
        var count: Int { buffer.count }

        func drain() -> [AgentEvent] {
          defer { buffer.removeAll() }
          return buffer.events.filter { !$0.isStale } // 古い知らせは捨てる——描画は最新の状態だけを見せればよく、溜まった分を順に流すと遅れて見える
        }
      }

      """

    /// 作業ツリーの書き換え（見本の `diffLines` と同じ形）。
    static var edited: String {
      original.replacingOccurrences(
        of: """
            func applyEmit(_ event: AgentEvent) {
              buffer.append(event)
              renderer.notify(.hooksDidEmit)
            }

          """,
        with: """
            func emit(_ event: AgentEvent, coalesce: Bool = true) {
              queue.async { [weak self] in
                guard let self else { return }
                if coalesce, let last = self.buffer.tail, last.merges(event) {
                  self.buffer.replaceTail(with: last.merged(event))
                } else {
                  self.buffer.append(event)
                }
                self.renderer.notify(.hooksDidEmit)
              }
            }

          """)
    }

    /// 削除の多い区間を持つ断片（作業ツリーで中ほどの 18 行を消す）。
    static let legacy = (0..<40).map { index in
      index % 5 == 0
        ? "  // 区画 \(index / 5): 旧い経路の互換（\"v\(index)\" の鍵で引く）"
        : "  let legacy\(index) = Table.lookup(\"v\(index)\", fallback: \(index))"
    }.joined(separator: "\n")

    @MainActor final class Scene {
      let tab: TerminalTab
      /// fixture のリポジトリ（置き場の下。消すのは置き場の持ち主）。
      let directory: URL
      var pane: EditorPaneView { tab.view.editor }
      var root: String { GitWorktreeRoot.normalizedPath(directory.path) }

      init(tab: TerminalTab, directory: URL) {
        self.tab = tab
        self.directory = directory
      }

      /// diff の識別。
      func key(_ path: String, _ kind: EditorDiff.Kind) -> EditorDiff.Key {
        EditorDiff.Key(root: root, path: path, kind: kind)
      }

      func cleanup() {
        pane.removeFromSuperview()
      }
    }

    /// リポジトリは `place` の下に作る。git が失敗すれば投げる（→ `FixtureGit`）。
    @MainActor static func scene(queriesRoot: URL, in place: URL) throws -> Scene {
      let dir = place.appendingPathComponent(
        "orbe-editor-diff-\(UUID().uuidString)", isDirectory: true)
      let write = { (path: String, text: String) in
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
      }
      try write("Sources/HookBuffer.swift", original)
      try write("Sources/Legacy.swift", "enum Legacy {\n\(legacy)\n}\n")
      try write("docs/notes.md", "# メモ\n\n- 知らせは描画の前に畳む\n")
      let git = FixtureGit(directory: dir)
      try git(["init", "-q", "-b", "main"])
      try git(["config", "user.email", "gallery@orbe.dev"])
      try git(["config", "user.name", "gallery"])
      try git(["add", "-A"])
      try git(["commit", "-qm", "gallery"])
      try write("Sources/HookBuffer.swift", edited)
      let kept = legacy.split(separator: "\n", omittingEmptySubsequences: false)
      try write(
        "Sources/Legacy.swift",
        "enum Legacy {\n\((kept[..<10] + kept[28...]).joined(separator: "\n"))\n}\n")
      try git(["mv", "docs/notes.md", "docs/guide.md"])
      try write("docs/guide.md", "# メモ\n\n- 知らせは描画の前に畳む\n- 古い知らせは捨てる\n")
      try git(["add", "docs/guide.md"])
      try Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE, 0x00]).write(
        to: dir.appendingPathComponent("icon.bin"))
      try git(["add", "icon.bin"])
      let tab = TerminalTab(
        cwd: dir.path,
        editorSurfaces: EditorSurfaces(queriesRoot: queriesRoot, language: { .ja }))
      return Scene(tab: tab, directory: dir)
    }
  }
#endif
