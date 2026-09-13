#if DEBUG
  import AppKit
  import SwiftUI

  /// コードビューの gallery fixture。本物の面（STTextView）に実在のコード断片を開き、pane ごと描く。
  /// queries の根はテストが渡す（テスト実行体は同梱物を持たないので `.build/<config>` を明示注入）。
  enum EditorCodeFixtures {
    /// `LineIndex` の実装をそのまま写した断片（見本の展示データは写さない）。
    static let sample = """
      import Foundation

      /// 行頭オフセット（UTF-16）の索引。行は `\\n` で区切る。
      public struct LineIndex: Equatable, Sendable {
        private var starts: [Int]

        public init(text: String) {
          starts = [0] + Self.lineStarts(in: text, base: 0)
        }

        public var lineCount: Int { starts.count }

        /// オフセットが属する行と、行頭からの距離。
        public func point(at offset: Int) -> (row: Int, column: Int) {
          let row = rowIndex(containing: offset)
          return (row, offset - starts[row])
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

        private static func lineStarts(in text: String, base: Int) -> [Int] {
          var result: [Int] = []
          var offset = base
          for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { result.append(offset) }
          }
          return result
        }
      }

      """

    /// 1 文書を開いた pane。gallery が dark / light を撮る。
    @MainActor static func gallery(queriesRoot: URL) -> some View {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbe-editor-gallery-\(ProcessInfo.processInfo.processIdentifier)")
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let url = dir.appendingPathComponent("LineIndex.swift")
      try? Data(sample.utf8).write(to: url)
      let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: queriesRoot))
      try? tab.editor.open(url)
      return CodePane(tab: tab)
    }

    private struct CodePane: NSViewRepresentable {
      let tab: TerminalTab

      func makeNSView(context: Context) -> EditorPaneView { tab.view.editor }

      func updateNSView(_ view: EditorPaneView, context: Context) {}
    }
  }

  #Preview("EditorCodeView") {
    EditorCodeFixtures.gallery(
      queriesRoot: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug")
    ).frame(width: 640, height: 480)
  }
#endif
