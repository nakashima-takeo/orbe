#if DEBUG
  import AppKit
  import OrbeEditorCore
  import SwiftUI

  /// コードビューの gallery / flow fixture。凍結した実コードの断片（`LineIndex` の実装を写したもの）を一時 git
  /// リポジトリにコミットし、作業ツリーで行の挿入・書き換え・削除・行末スペースを起こしてから開く——追加＝緑・
  /// 変更＝青・削除＝赤の三角、インデント線、丸点、URL の下線が 1 枚に写る。中身が動く生きたファイルは写さない
  /// （絵が安定しない）。baseline は git の子プロセス後に届くので、撮る側は `isReady` を待つ。
  enum EditorCodeFixtures {
    static let sample = """
      import Foundation

      /// 行頭オフセット（UTF-16）の索引。行は `\\n` で区切る。
      /// 数え方は tree-sitter と同じ: https://tree-sitter.github.io/tree-sitter/using-parsers
      public struct LineIndex: Equatable, Sendable {
        private var starts: [Int]

        public init(text: String) {
          starts = [0] + Self.lineStarts(in: text, base: 0)
        }

        public var lineCount: Int { starts.count }

        /// オフセットが属する行と、行頭からの距離。
        public func point(at offset: Int) -> (row: Int, column: Int) {
          let row = rowIndex(containing: offset)  // 二分探索
          return (row, offset - starts[row])
        }

        private static func lineStarts(in text: String, base: Int) -> [Int] {
          var result: [Int] = []
          var offset = base
          for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { result.append(offset) }
          }
          return result
        }

        public mutating func apply(_ edit: TextEdit, replacement: String) {
          let removedEnd = NSMaxRange(edit.range)
          let delta = edit.replacementLength - edit.range.length
          let firstAffected = starts.firstIndex { $0 > edit.range.location } ?? starts.count
          let firstKept = starts.firstIndex { $0 > removedEnd } ?? starts.count
          let inserted = Self.lineStarts(in: replacement, base: edit.range.location)
          let tail = starts[firstKept...].map { $0 + delta }
          starts.replaceSubrange(firstAffected..., with: inserted + tail)
        }
      }

      """

    /// コミット済みの断片に作業ツリーで起こす変更: `starts` の下の空行を消す（削除）、`lineCount` の下に 2 行
    /// 足す（追加）、`point` の 2 行を書き換える（変更。1 行は行末にスペース 2 つ＝丸点）。
    static var edited: String {
      sample
        .replacingOccurrences(
          of: "  private var starts: [Int]\n\n", with: "  private var starts: [Int]\n"
        )
        .replacingOccurrences(
          of: "  public var lineCount: Int { starts.count }\n",
          with: """
              public var lineCount: Int { starts.count }

              public var isEmpty: Bool { lineCount == 1 }

            """
        )
        .replacingOccurrences(
          of: "    let row = rowIndex(containing: offset)  // 二分探索\n",
          with: "    let row = rowIndex(containing: offset)  // 二分探索で行を引く\n"
        )
        .replacingOccurrences(
          of: "    return (row, offset - starts[row])\n",
          with: "    return (row, offset - starts[row])  \n")
    }

    @MainActor final class Scene {
      let tab: TerminalTab
      let document: EditorDocument
      /// 一時リポジトリ（`cleanup()` で消す）。
      let directory: URL
      var pane: EditorPaneView { tab.view.editor }

      init(tab: TerminalTab, document: EditorDocument, directory: URL) {
        self.tab = tab
        self.document = document
        self.directory = directory
      }

      /// index 版が届いて印が揃った。
      var isReady: Bool { document.baseline != nil }

      /// 撮る view（pane をそのまま載せる）。
      var view: some View { CodePane(pane: pane) }

      func cleanup() {
        pane.removeFromSuperview()
        try? FileManager.default.removeItem(at: directory)
      }
    }

    struct GitFailure: Error {
      let arguments: [String]
      let stderr: String
    }

    /// git が失敗すれば投げる（握り潰すと `isReady` の待ちが原因を指さずに落ちる）。
    @MainActor static func scene(queriesRoot: URL) throws -> Scene {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbe-editor-code-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let url = dir.appendingPathComponent("LineIndex.swift")
      try Data(sample.utf8).write(to: url)
      let git = { (args: [String]) throws in
        let output = GitRunner.shared.runSync(args, cwd: dir.path)
        guard output.isSuccess else {
          throw GitFailure(
            arguments: args, stderr: String(bytes: output.stderr, encoding: .utf8) ?? "")
        }
      }
      try git(["init", "-q", "-b", "main"])
      try git(["config", "user.email", "gallery@orbe.dev"])
      try git(["config", "user.name", "gallery"])
      try git(["add", "-A"])
      try git(["commit", "-qm", "gallery"])
      try Data(edited.utf8).write(to: url)
      let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: queriesRoot))
      let document = try tab.editor.open(url)
      return Scene(tab: tab, document: document, directory: dir)
    }

    private struct CodePane: NSViewRepresentable {
      let pane: EditorPaneView

      func makeNSView(context: Context) -> EditorPaneView { pane }

      func updateNSView(_ view: EditorPaneView, context: Context) {}
    }
  }

  #Preview("EditorCodeView") {
    (try? EditorCodeFixtures.scene(
      queriesRoot: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug")
    ))?.view.frame(width: 1000, height: 480)
  }
#endif
