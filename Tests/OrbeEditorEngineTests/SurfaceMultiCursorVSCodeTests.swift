import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 複数カーソルの規則を、VS Code を動かした正解（`VSCodeMultiCursorCases`）と面の上で突き合わせる——同じ本文とカーソルの
/// 列から、同じ操作を面のセレクタ（キーの割り当てが呼ぶもの）・Esc・専用のペーストボードのコピー／カット／ペーストで
/// 当て、1 手ごとに本文とカーソルの列（主が先頭、足した順）と写したものが一致する。壊れると ⌘D・⌘⇧L・⌥⌘↑↓・⌘U・Esc・
/// 全カーソルでの編集と移動・配る貼り付け・重なったカーソルのまとめ方のどれかが VS Code と違う結果になる。
@MainActor
final class SurfaceMultiCursorVSCodeTests: EngineTestCase {
  private typealias Cases = VSCodeMultiCursorCases

  /// VS Code のコマンドの名前 → 面のセレクタ（macOS のキー割り当てが同じキーで呼ぶもの）。
  private static let selectors: [String: Selector] = [
    "editor.action.addSelectionToNextFindMatch": #selector(
      MetalTextView.addSelectionToNextFindMatch(_:)),
    "editor.action.selectHighlights": #selector(MetalTextView.selectHighlights(_:)),
    "editor.action.insertCursorAbove": #selector(MetalTextView.insertCursorAbove(_:)),
    "editor.action.insertCursorBelow": #selector(MetalTextView.insertCursorBelow(_:)),
    "cursorUndo": #selector(MetalTextView.cursorUndo(_:)),
    "deleteLeft": #selector(NSResponder.deleteBackward(_:)),
    "deleteRight": #selector(NSResponder.deleteForward(_:)),
    "deleteWordLeft": #selector(NSResponder.deleteWordBackward(_:)),
    "tab": #selector(NSResponder.insertTab(_:)),
    "outdent": #selector(NSResponder.insertBacktab(_:)),
    "cursorLeft": #selector(NSResponder.moveLeft(_:)),
    "cursorRight": #selector(NSResponder.moveRight(_:)),
    "cursorUp": #selector(NSResponder.moveUp(_:)),
    "cursorDown": #selector(NSResponder.moveDown(_:)),
    "cursorLeftSelect": #selector(NSResponder.moveLeftAndModifySelection(_:)),
    "cursorRightSelect": #selector(NSResponder.moveRightAndModifySelection(_:)),
    "cursorUpSelect": #selector(NSResponder.moveUpAndModifySelection(_:)),
    "cursorDownSelect": #selector(NSResponder.moveDownAndModifySelection(_:)),
    "cursorWordLeft": #selector(NSResponder.moveWordLeft(_:)),
    "cursorWordEndRight": #selector(NSResponder.moveWordRight(_:)),
    "cursorWordLeftSelect": #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
    "cursorWordEndRightSelect": #selector(NSResponder.moveWordRightAndModifySelection(_:)),
    "cursorHome": #selector(NSResponder.moveToLeftEndOfLine(_:)),
    "cursorEnd": #selector(NSResponder.moveToRightEndOfLine(_:)),
    "cursorHomeSelect": #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)),
  ]

  /// VS Code と意図して変えたところ（場面の名前 → 理由）。この場面はカーソルの列を比べず、本文と写したものだけを比べる。
  private static let differences: [String: String] = [
    "⌘D は日本語の並びの中の語を選ぶ":
      "語は ⌥←→・ダブルクリックと同じく日本語の並びを OS の語の分割で切る（VS Code は並び全体を 1 語にする）",
    "⌥⌘↓ は全角の字の行から横位置を写す":
      "横位置は ↑↓ と同じく描いた pt で覚える（VS Code は全角の字を 2 桁と数える）",
    "配る行が空のカーソルも他のカーソルが入れた分だけずれる":
      "VS Code は空の行を配ったカーソルの編集を捨て、そのキャレットを前のカーソルが入れた分だけずらさない（前のカーソルが"
      + "入れた字の中に入る）。Orbe は元の字の前に残す",
  ]

  /// 全手順の本文・カーソルの列・写したものが VS Code と一致する。
  func testMultiCursorRulesMatchVSCode() throws {
    XCTAssertGreaterThan(Cases.cases.count, 50)
    let names = Set(Cases.cases.map(\.name))
    for name in Self.differences.keys { XCTAssertTrue(names.contains(name), "無い場面: \(name)") }
    for c in Cases.cases {
      let comparesCursors = Self.differences[c.name] == nil
      let opened = try open(c.text, name: "a.txt", waitForColors: false)
      _ = host(opened)
      let board = privatePasteboard(opened)
      place(opened, c.cursors)
      for (index, step) in c.steps.enumerated() {
        let label = "\(c.name) の \(index + 1) 手目（\(step.action)）"
        try act(step.action, opened, board)
        XCTAssertEqual(text(opened.document), step.text, "本文: \(label)")
        if comparesCursors {
          XCTAssertEqual(cursors(opened), step.cursors, "カーソル: \(label)")
        }
        if let clipboard = step.clipboard {
          XCTAssertEqual(copied(board), clipboard, "写したもの: \(label)")
        }
      }
    }
  }

  /// カーソルの上限で切る位置と、切った後の主と最後のカーソルが VS Code と一致する。
  func testCursorLimitMatchesVSCode() throws {
    for c in Cases.limits {
      let opened = try open(
        String(repeating: c.unit, count: c.count), name: "a.txt", waitForColors: false)
      _ = host(opened)
      let board = privatePasteboard(opened)
      place(opened, [[c.caret, c.caret]])
      for action in c.actions { try act(action, opened, board) }
      let all = cursors(opened)
      XCTAssertEqual(all.count, c.cursorCount, c.name)
      XCTAssertEqual(all.first, c.primary, "主: \(c.name)")
      XCTAssertEqual(all.last, c.last, "最後: \(c.name)")
    }
  }

  private func place(_ opened: Opened, _ cursors: [[Int]]) {
    let list = cursors.map {
      Cursor(
        selectionStart: NSRange(location: $0[0], length: 0), unit: .character, position: $0[1])
    }
    let surface = opened.surface
    surface.inputScope {
      surface.editor.select(CursorList(list[0], others: Array(list.dropFirst())), reveal: .none)
    }
  }

  private func cursors(_ opened: Opened) -> [[Int]] {
    opened.surface.editor.state.cursors.all.map { [$0.anchor, $0.position] }
  }

  private func copied(_ board: NSPasteboard) -> Cases.Clipboard {
    Cases.Clipboard(
      text: board.string(forType: .string) ?? "",
      pieces: board.propertyList(forType: MetalTextView.piecesType) as? [String],
      entireLine: board.availableType(from: [MetalTextView.entireLineType]) != nil)
  }

  private func act(_ action: Cases.Action, _ opened: Opened, _ board: NSPasteboard) throws {
    let view = opened.surface.textView
    switch action {
    case .command(let name):
      view.perform(try XCTUnwrap(Self.selectors[name], "面のセレクタの無いコマンド: \(name)"), with: nil)
    case .type(let string):
      for character in string {
        if character == "\n" { view.insertNewline(nil) } else { view.insertText(String(character)) }
      }
    case .escape: view.cancelOperation(nil)
    case .copy: view.copy(nil)
    case .cut: view.cut(nil)
    case .paste: view.paste(nil)
    case .pasteExternal(let string):
      board.declareTypes([.string], owner: nil)
      board.setString(string, forType: .string)
      view.paste(nil)
    }
  }
}
