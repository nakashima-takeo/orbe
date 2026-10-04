// swiftlint:disable file_length type_body_length

/// VS Code の複数カーソルの規則の正解——monaco-editor 0.57.0 の編集器（jsdom の上）で、カーソルの列を置いて
/// 操作を順に当てた結果（scripts/gen-vscode-edit-cases.sh が生成する。手で直さない）。位置はどれも本文のオフセット。
/// カーソルは [動かない端, 動く端] で、列の先頭が主（VS Code の `getSelections()` の順）。
enum VSCodeMultiCursorCases {
  /// 当てる操作。`command` は VS Code のコマンドの名前。`escape` は Esc の割り当て（カーソルが複数なら
  /// `removeSecondaryCursors`、1 本で選択があれば `cancelSelection`）。`paste` は直前に写したもの（行ごと写した印と断片
  /// つき）を、`pasteExternal` は印も断片も無い文字列を貼る。
  enum Action: Equatable {
    case command(String)
    case type(String)
    case escape, copy, cut, paste
    case pasteExternal(String)
  }

  /// 写したもの。`pieces` は VS Code の `multicursorText`、`entireLine` は `isFromEmptySelection`。
  struct Clipboard: Equatable {
    let text: String
    let pieces: [String]?
    let entireLine: Bool
  }

  struct Step {
    let action: Action
    let text: String
    let cursors: [[Int]]
    var clipboard: Clipboard?
  }

  struct Case {
    let name: String
    let text: String
    let cursors: [[Int]]
    let steps: [Step]
  }

  /// 本文が `unit` を `count` 回並べたもの、カーソルが `caret` のキャレット 1 本から、`actions` を当てた結果の数と主と
  /// 最後のカーソル。
  struct LimitCase {
    let name: String
    let unit: String
    let count: Int
    let caret: Int
    let actions: [Action]
    let cursorCount: Int
    let primary: [Int]
    let last: [Int]
  }

  static let cases: [Case] = [
    .init(
      name: "⌘D は空のキャレットから語を選び語の単位・大小区別で足して回る", text: "foo bar Bar bar barx bar\nbar",
      cursors: [[5, 5]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"),
          text: "foo bar Bar bar barx bar\nbar", cursors: [[4, 7]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"),
          text: "foo bar Bar bar barx bar\nbar", cursors: [[4, 7], [12, 15]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"),
          text: "foo bar Bar bar barx bar\nbar", cursors: [[4, 7], [12, 15], [21, 24]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"),
          text: "foo bar Bar bar barx bar\nbar",
          cursors: [[4, 7], [12, 15], [21, 24], [25, 28]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"),
          text: "foo bar Bar bar barx bar\nbar",
          cursors: [[4, 7], [12, 15], [21, 24], [25, 28]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"),
          text: "foo bar Bar bar barx bar\nbar",
          cursors: [[4, 7], [12, 15], [21, 24], [25, 28]]),
      ]),
    .init(
      name: "⌘D は語の終わりのキャレットからも語を選ぶ", text: "ab cd cd",
      cursors: [[5, 5]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab cd cd",
          cursors: [[3, 5]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab cd cd",
          cursors: [[3, 5], [6, 8]]),
      ]),
    .init(
      name: "⌘D は語に接しないキャレットでは何もしない", text: "a    b a",
      cursors: [[3, 3]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "a    b a",
          cursors: [[3, 3]])
      ]),
    .init(
      name: "⌘D は最後に足した選択の後ろから探して先頭へ回る", text: "x foo foo foo foo",
      cursors: [[10, 10]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "x foo foo foo foo",
          cursors: [[10, 13]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "x foo foo foo foo",
          cursors: [[10, 13], [14, 17]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "x foo foo foo foo",
          cursors: [[10, 13], [14, 17], [2, 5]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "x foo foo foo foo",
          cursors: [[10, 13], [14, 17], [2, 5], [6, 9]]),
      ]),
    .init(
      name: "⌘D は選択から大小を区別しない素の文字列で足す", text: "abc AB xab\nAb",
      cursors: [[0, 2]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "abc AB xab\nAb",
          cursors: [[0, 2], [4, 6]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "abc AB xab\nAb",
          cursors: [[0, 2], [4, 6], [8, 10]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "abc AB xab\nAb",
          cursors: [[0, 2], [4, 6], [8, 10], [11, 13]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "abc AB xab\nAb",
          cursors: [[0, 2], [4, 6], [8, 10], [11, 13]]),
      ]),
    .init(
      name: "⌘D は逆向きの選択からも足す", text: "ab x ab ab",
      cursors: [[2, 0]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab x ab ab",
          cursors: [[2, 0], [5, 7]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab x ab ab",
          cursors: [[2, 0], [5, 7], [8, 10]]),
      ]),
    .init(
      name: "⌘D は重なりうる一致を重ねずに足す", text: "aaaaa",
      cursors: [[0, 2]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "aaaaa",
          cursors: [[0, 2], [2, 4]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "aaaaa",
          cursors: [[0, 2], [2, 4]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "aaaaa",
          cursors: [[0, 2], [2, 4]]),
      ]),
    .init(
      name: "⌘D は複数行の選択の一致を足す", text: "a\nb a\nb a\nb",
      cursors: [[0, 3]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "a\nb a\nb a\nb",
          cursors: [[0, 3], [4, 7]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "a\nb a\nb a\nb",
          cursors: [[0, 3], [4, 7], [8, 11]]),
      ]),
    .init(
      name: "⌘D はそろっていない空のカーソルを語に広げるだけ", text: "abc xyz abc xyz",
      cursors: [[1, 1], [5, 5]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "abc xyz abc xyz",
          cursors: [[0, 3], [4, 7]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "abc xyz abc xyz",
          cursors: [[0, 3], [4, 7]]),
      ]),
    .init(
      name: "⌘D は空のカーソルと選択が混ざれば広げるだけ", text: "abc abc abc",
      cursors: [[0, 3], [7, 7]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "abc abc abc",
          cursors: [[0, 3], [4, 7]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "abc abc abc",
          cursors: [[0, 3], [4, 7], [8, 11]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "abc abc abc",
          cursors: [[0, 3], [4, 7], [8, 11]]),
      ]),
    .init(
      name: "⌘D は日本語の並びの中の語を選ぶ", text: "東京都に行く。東京タワー",
      cursors: [[2, 2]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "東京都に行く。東京タワー",
          cursors: [[0, 12]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "東京都に行く。東京タワー",
          cursors: [[0, 12]]),
      ]),
    .init(
      name: "⌘D はそろった選択の列から主で続きを作る", text: "ab x AB ab ab",
      cursors: [[0, 2], [5, 7]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab x AB ab ab",
          cursors: [[0, 2], [5, 7], [8, 10]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab x AB ab ab",
          cursors: [[0, 2], [5, 7], [8, 10], [11, 13]]),
      ]),
    .init(
      name: "⌘D は主が後ろのそろった選択から続きを作る", text: "ab x ab ab ab",
      cursors: [[5, 7], [0, 2]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab x ab ab ab",
          cursors: [[5, 7], [0, 2]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab x ab ab ab",
          cursors: [[5, 7], [0, 2]]),
      ]),
    .init(
      name: "⌘⇧L は選択の全出現を選び主の場所を保つ", text: "x ab y AB ab z ab",
      cursors: [[10, 12]],
      steps: [
        .init(
          action: .command("editor.action.selectHighlights"), text: "x ab y AB ab z ab",
          cursors: [[10, 12], [7, 9], [2, 4], [15, 17]])
      ]),
    .init(
      name: "⌘⇧L は空のキャレットから語の全出現を選ぶ", text: "ab x ab y abc AB ab",
      cursors: [[6, 6]],
      steps: [
        .init(
          action: .command("editor.action.selectHighlights"), text: "ab x ab y abc AB ab",
          cursors: [[5, 7], [0, 2], [17, 19]])
      ]),
    .init(
      name: "⌘⇧L は ⌘D の続きの全出現を選ぶ", text: "ab x ab ab",
      cursors: [[1, 1]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab x ab ab",
          cursors: [[0, 2]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab x ab ab",
          cursors: [[0, 2], [5, 7]]),
        .init(
          action: .command("editor.action.selectHighlights"), text: "ab x ab ab",
          cursors: [[0, 2], [5, 7], [8, 10]]),
      ]),
    .init(
      name: "⌘⇧L は一致が 1 つなら主だけ", text: "xyz abc",
      cursors: [[0, 3]],
      steps: [
        .init(
          action: .command("editor.action.selectHighlights"), text: "xyz abc", cursors: [[0, 3]])
      ]),
    .init(
      name: "⌘⇧L は語の無いキャレットでは何もしない", text: "a  b",
      cursors: [[2, 2]],
      steps: [
        .init(action: .command("editor.action.selectHighlights"), text: "a  b", cursors: [[2, 2]])
      ]),
    .init(
      name: "⌘⇧L はカーソルが複数でも主から始める", text: "ab ab cd cd",
      cursors: [[7, 7], [1, 1]],
      steps: [
        .init(
          action: .command("editor.action.selectHighlights"), text: "ab ab cd cd",
          cursors: [[6, 8], [9, 11]])
      ]),
    .init(
      name: "⌥⌘↓ は短い行を越えて覚えた横位置へ戻る", text: "abcd\nx\n\nabcdef\nab",
      cursors: [[3, 3]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nx\n\nabcdef\nab",
          cursors: [[3, 3], [6, 6]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nx\n\nabcdef\nab",
          cursors: [[3, 3], [6, 6], [7, 7]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nx\n\nabcdef\nab",
          cursors: [[3, 3], [6, 6], [7, 7], [11, 11]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nx\n\nabcdef\nab",
          cursors: [[3, 3], [6, 6], [7, 7], [11, 11], [17, 17]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nx\n\nabcdef\nab",
          cursors: [[3, 3], [6, 6], [7, 7], [11, 11], [17, 17]]),
      ]),
    .init(
      name: "⌥⌘↑ は短い行を越えて覚えた横位置へ戻る", text: "ab\nabcdef\n\nx\nabcd",
      cursors: [[16, 16]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "ab\nabcdef\n\nx\nabcd",
          cursors: [[16, 16], [12, 12]]),
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "ab\nabcdef\n\nx\nabcd",
          cursors: [[16, 16], [12, 12], [10, 10]]),
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "ab\nabcdef\n\nx\nabcd",
          cursors: [[16, 16], [12, 12], [10, 10], [6, 6]]),
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "ab\nabcdef\n\nx\nabcd",
          cursors: [[16, 16], [12, 12], [10, 10], [6, 6], [2, 2]]),
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "ab\nabcdef\n\nx\nabcd",
          cursors: [[16, 16], [12, 12], [10, 10], [6, 6], [2, 2]]),
      ]),
    .init(
      name: "⌥⌘↓ は選択の両端を写す", text: "abcd\nxyzw\nq\nabcd",
      cursors: [[1, 3]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nxyzw\nq\nabcd",
          cursors: [[1, 3], [6, 8]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nxyzw\nq\nabcd",
          cursors: [[1, 3], [6, 8], [11, 11]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nxyzw\nq\nabcd",
          cursors: [[1, 3], [6, 8], [11, 11], [13, 15]]),
      ]),
    .init(
      name: "⌥⌘↓ は逆向きの選択の両端を写す", text: "abcd\nxyzw\nabcd",
      cursors: [[3, 1]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nxyzw\nabcd",
          cursors: [[3, 1], [8, 6]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abcd\nxyzw\nabcd",
          cursors: [[3, 1], [8, 6], [13, 11]]),
      ]),
    .init(
      name: "⌥⌘↓ は行をまたぐ選択を写す", text: "ab\ncde\nfghi\njk",
      cursors: [[1, 5]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "ab\ncde\nfghi\njk",
          cursors: [[1, 9]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "ab\ncde\nfghi\njk",
          cursors: [[1, 14]]),
      ]),
    .init(
      name: "⌥⌘↓ は最終行の下には足さない", text: "abc\nxy",
      cursors: [[5, 5]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abc\nxy", cursors: [[5, 5]]),
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "abc\nxy",
          cursors: [[5, 5], [1, 1]]),
      ]),
    .init(
      name: "⌥⌘↑ は先頭行の上には足さない", text: "abc\nxy",
      cursors: [[1, 1]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "abc\nxy", cursors: [[1, 1]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abc\nxy",
          cursors: [[1, 1], [5, 5]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abc\nxy",
          cursors: [[1, 1], [5, 5]]),
      ]),
    .init(
      name: "⌥⌘↓ は複数のカーソルそれぞれの下に足して重なりをまとめる", text: "ab\ncd\nef\ngh",
      cursors: [[1, 1], [4, 4]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "ab\ncd\nef\ngh",
          cursors: [[1, 1], [4, 4], [7, 7]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "ab\ncd\nef\ngh",
          cursors: [[1, 1], [4, 4], [7, 7], [10, 10]]),
      ]),
    .init(
      name: "⌥⌘↑ は複数のカーソルそれぞれの上に足す", text: "ab\ncd\nef\ngh",
      cursors: [[10, 10], [7, 7]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "ab\ncd\nef\ngh",
          cursors: [[10, 10], [7, 7], [4, 4]]),
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "ab\ncd\nef\ngh",
          cursors: [[10, 10], [7, 7], [4, 4], [1, 1]]),
      ]),
    .init(
      name: "⌥⌘↓ は全角の字の行から横位置を写す", text: "あいう\nabcdef",
      cursors: [[2, 2]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "あいう\nabcdef",
          cursors: [[2, 2], [8, 8]])
      ]),
    .init(
      name: "⌥⌘↓ の後の打鍵は全カーソルに入る", text: "ab\ncd\nef",
      cursors: [[1, 1]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "ab\ncd\nef",
          cursors: [[1, 1], [4, 4]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "ab\ncd\nef",
          cursors: [[1, 1], [4, 4], [7, 7]]),
        .init(action: .type("X"), text: "aXb\ncXd\neXf", cursors: [[2, 2], [6, 6], [10, 10]]),
        .init(
          action: .command("deleteLeft"), text: "ab\ncd\nef", cursors: [[1, 1], [4, 4], [7, 7]]),
      ]),
    .init(
      name: "⌘U は ⌘D の足し方を 1 つずつ戻し次の ⌘D がまた足す", text: "ab ab ab ab",
      cursors: [[1, 1]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab ab ab ab",
          cursors: [[0, 2]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab ab ab ab",
          cursors: [[0, 2], [3, 5]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab ab ab ab",
          cursors: [[0, 2], [3, 5], [6, 8]]),
        .init(action: .command("cursorUndo"), text: "ab ab ab ab", cursors: [[0, 2], [3, 5]]),
        .init(action: .command("cursorUndo"), text: "ab ab ab ab", cursors: [[0, 2]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab ab ab ab",
          cursors: [[0, 2], [3, 5]]),
      ]),
    .init(
      name: "⌘U は移動と ⌥⌘↓ を戻す", text: "abc\nabc\nabc",
      cursors: [[0, 0]],
      steps: [
        .init(action: .command("cursorRight"), text: "abc\nabc\nabc", cursors: [[1, 1]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abc\nabc\nabc",
          cursors: [[1, 1], [5, 5]]),
        .init(action: .command("cursorRight"), text: "abc\nabc\nabc", cursors: [[2, 2], [6, 6]]),
        .init(action: .command("cursorUndo"), text: "abc\nabc\nabc", cursors: [[1, 1], [5, 5]]),
        .init(action: .command("cursorUndo"), text: "abc\nabc\nabc", cursors: [[1, 1]]),
        .init(action: .command("cursorUndo"), text: "abc\nabc\nabc", cursors: [[0, 0]]),
      ]),
    .init(
      name: "⌘U は本文を変えると戻すものが無い", text: "ab ab ab",
      cursors: [[1, 1]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab ab ab",
          cursors: [[0, 2]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "ab ab ab",
          cursors: [[0, 2], [3, 5]]),
        .init(action: .type("x"), text: "x x ab", cursors: [[1, 1], [3, 3]]),
        .init(action: .command("cursorUndo"), text: "x x ab", cursors: [[1, 1], [3, 3]]),
      ]),
    .init(
      name: "⌘U は戻すものが無ければ何もしない", text: "ab",
      cursors: [[1, 1]],
      steps: [
        .init(action: .command("cursorUndo"), text: "ab", cursors: [[0, 0]])
      ]),
    .init(
      name: "Esc は主の 1 本に戻し選択を残し次に選択を解く", text: "ab ab ab",
      cursors: [[0, 2], [3, 5], [6, 8]],
      steps: [
        .init(action: .escape, text: "ab ab ab", cursors: [[0, 2]]),
        .init(action: .escape, text: "ab ab ab", cursors: [[2, 2]]),
        .init(action: .escape, text: "ab ab ab", cursors: [[2, 2]]),
      ]),
    .init(
      name: "Esc は主が文書の後ろでも主を残す", text: "ab ab ab",
      cursors: [[6, 8], [0, 2], [3, 5]],
      steps: [
        .init(action: .escape, text: "ab ab ab", cursors: [[6, 8]])
      ]),
    .init(
      name: "Esc は ⌘D で足した後も主の選択を残す", text: "xy xy xy",
      cursors: [[1, 1]],
      steps: [
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "xy xy xy",
          cursors: [[0, 2]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "xy xy xy",
          cursors: [[0, 2], [3, 5]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "xy xy xy",
          cursors: [[0, 2], [3, 5], [6, 8]]),
        .init(action: .escape, text: "xy xy xy", cursors: [[0, 2]]),
        .init(action: .escape, text: "xy xy xy", cursors: [[2, 2]]),
      ]),
    .init(
      name: "Esc は逆向きの選択を動く端のキャレットにする", text: "ab x",
      cursors: [[2, 0]],
      steps: [
        .init(action: .escape, text: "ab x", cursors: [[0, 0]])
      ]),
    .init(
      name: "Esc はキャレットが複数なら主に戻す", text: "ab cd ef",
      cursors: [[4, 4], [1, 1], [7, 7]],
      steps: [
        .init(action: .escape, text: "ab cd ef", cursors: [[4, 4]]),
        .init(action: .escape, text: "ab cd ef", cursors: [[4, 4]]),
      ]),
    .init(
      name: "打鍵は全キャレットに入る", text: "ab\ncd\n",
      cursors: [[1, 1], [4, 4], [6, 6]],
      steps: [
        .init(action: .type("x"), text: "axb\ncxd\nx", cursors: [[2, 2], [6, 6], [9, 9]]),
        .init(
          action: .type("yz"), text: "axyzb\ncxyzd\nxyz", cursors: [[4, 4], [10, 10], [15, 15]]),
      ]),
    .init(
      name: "打鍵は全選択を置き換える", text: "ab c ab d ab",
      cursors: [[0, 2], [5, 7], [12, 10]],
      steps: [
        .init(action: .type("Z"), text: "Z c Z d Z", cursors: [[1, 1], [5, 5], [9, 9]])
      ]),
    .init(
      name: "改行を含む打鍵は全カーソルに入る", text: "ab cd",
      cursors: [[1, 1], [4, 4]],
      steps: [
        .init(action: .type("1\n2"), text: "a1\n2b c1\n2d", cursors: [[4, 4], [10, 10]])
      ]),
    .init(
      name: "⌫ は全キャレットの前の字を消し行頭なら行をつなぐ", text: "ab\ncd\nefg",
      cursors: [[2, 2], [3, 3], [8, 8]],
      steps: [
        .init(action: .command("deleteLeft"), text: "acd\neg", cursors: [[1, 1], [5, 5]]),
        .init(action: .command("deleteLeft"), text: "cd\ng", cursors: [[0, 0], [3, 3]]),
      ]),
    .init(
      name: "⌫ は接するキャレットの消し方をまとめる", text: "abcd",
      cursors: [[1, 1], [2, 2], [3, 3]],
      steps: [
        .init(action: .command("deleteLeft"), text: "d", cursors: [[0, 0]]),
        .init(action: .command("deleteLeft"), text: "d", cursors: [[0, 0]]),
      ]),
    .init(
      name: "⌫ は選択とキャレットが混ざっても全部に当たる", text: "abcd efgh",
      cursors: [[0, 2], [3, 3], [8, 6]],
      steps: [
        .init(action: .command("deleteLeft"), text: "d eh", cursors: [[0, 0], [3, 3]])
      ]),
    .init(
      name: "⌦ は全キャレットの後ろの字を消し行末なら行をつなぐ", text: "ab\ncd\nef",
      cursors: [[1, 1], [2, 2], [5, 5], [6, 6]],
      steps: [
        .init(action: .command("deleteRight"), text: "acdf", cursors: [[1, 1], [3, 3]]),
        .init(action: .command("deleteRight"), text: "ad", cursors: [[1, 1], [2, 2]]),
      ]),
    .init(
      name: "⌦ は文書の終わりのキャレットでは消さない", text: "abc",
      cursors: [[2, 2], [3, 3]],
      steps: [
        .init(action: .command("deleteRight"), text: "ab", cursors: [[2, 2]]),
        .init(action: .command("deleteRight"), text: "ab", cursors: [[2, 2]]),
      ]),
    .init(
      name: "⌥⌫ は全キャレットの前の語を消す", text: "foo bar\nbaz.qux  x",
      cursors: [[7, 7], [15, 15], [18, 18]],
      steps: [
        .init(
          action: .command("deleteWordLeft"), text: "foo \nbaz.  ",
          cursors: [[4, 4], [9, 9], [11, 11]]),
        .init(action: .command("deleteWordLeft"), text: "\nbaz", cursors: [[0, 0], [4, 4]]),
      ]),
    .init(
      name: "改行は全カーソルで字下げを引き継ぐ", text: "  ab\n    cd",
      cursors: [[3, 3], [10, 10]],
      steps: [
        .init(action: .type("\n"), text: "  a\n  b\n    c\n    d", cursors: [[6, 6], [18, 18]])
      ]),
    .init(
      name: "←→ は全カーソルで選択の端へ畳み、重なればまとまる", text: "abc def",
      cursors: [[0, 2], [2, 2], [7, 5]],
      steps: [
        .init(action: .command("cursorLeft"), text: "abc def", cursors: [[0, 0], [5, 5]]),
        .init(action: .command("cursorRight"), text: "abc def", cursors: [[1, 1], [6, 6]]),
        .init(action: .command("cursorLeft"), text: "abc def", cursors: [[0, 0], [5, 5]]),
        .init(action: .command("cursorLeft"), text: "abc def", cursors: [[0, 0], [4, 4]]),
      ]),
    .init(
      name: "← は行頭のキャレットを前の行の終わりへ動かす", text: "ab\ncd\nef",
      cursors: [[3, 3], [6, 6]],
      steps: [
        .init(action: .command("cursorLeft"), text: "ab\ncd\nef", cursors: [[2, 2], [5, 5]]),
        .init(action: .command("cursorRight"), text: "ab\ncd\nef", cursors: [[3, 3], [6, 6]]),
        .init(action: .command("cursorRight"), text: "ab\ncd\nef", cursors: [[4, 4], [7, 7]]),
      ]),
    .init(
      name: "↑↓ はカーソルごとに覚えた横位置を保つ", text: "abcdef\nx\nabcdefgh\nab\nabcdefghij",
      cursors: [[4, 4], [16, 16]],
      steps: [
        .init(
          action: .command("cursorDown"), text: "abcdef\nx\nabcdefgh\nab\nabcdefghij",
          cursors: [[8, 8], [20, 20]]),
        .init(
          action: .command("cursorDown"), text: "abcdef\nx\nabcdefgh\nab\nabcdefghij",
          cursors: [[13, 13], [28, 28]]),
        .init(
          action: .command("cursorUp"), text: "abcdef\nx\nabcdefgh\nab\nabcdefghij",
          cursors: [[8, 8], [20, 20]]),
      ]),
    .init(
      name: "↑↓ は端の行で行頭・行末へ寄せ、重なればまとまる", text: "ab\ncd",
      cursors: [[1, 1], [4, 4]],
      steps: [
        .init(action: .command("cursorUp"), text: "ab\ncd", cursors: [[0, 0], [1, 1]]),
        .init(action: .command("cursorDown"), text: "ab\ncd", cursors: [[4, 4]]),
        .init(action: .command("cursorDown"), text: "ab\ncd", cursors: [[5, 5]]),
      ]),
    .init(
      name: "↓ は選択を畳んで下へ動く", text: "abc\ndef\nghi",
      cursors: [[1, 3], [7, 5]],
      steps: [
        .init(action: .command("cursorDown"), text: "abc\ndef\nghi", cursors: [[7, 7], [11, 11]])
      ]),
    .init(
      name: "⇧←→ は全カーソルで伸び、重なればまとまる", text: "abcd ef",
      cursors: [[1, 1], [2, 2], [6, 6]],
      steps: [
        .init(
          action: .command("cursorRightSelect"), text: "abcd ef",
          cursors: [[1, 2], [2, 3], [6, 7]]),
        .init(action: .command("cursorRightSelect"), text: "abcd ef", cursors: [[1, 4], [6, 7]]),
        .init(action: .command("cursorLeftSelect"), text: "abcd ef", cursors: [[1, 3], [6, 6]]),
        .init(action: .command("cursorLeftSelect"), text: "abcd ef", cursors: [[1, 2], [6, 5]]),
        .init(action: .command("cursorLeftSelect"), text: "abcd ef", cursors: [[1, 1], [6, 4]]),
        .init(action: .command("cursorLeftSelect"), text: "abcd ef", cursors: [[1, 0], [6, 3]]),
      ]),
    .init(
      name: "⇧← で前へ伸ばした選択が重なると最後に足した向きに倣う", text: "abcdef",
      cursors: [[4, 4], [2, 2]],
      steps: [
        .init(action: .command("cursorLeftSelect"), text: "abcdef", cursors: [[4, 3], [2, 1]]),
        .init(action: .command("cursorLeftSelect"), text: "abcdef", cursors: [[4, 2], [2, 0]]),
        .init(action: .command("cursorLeftSelect"), text: "abcdef", cursors: [[4, 0]]),
      ]),
    .init(
      name: "⇧↑↓ は全カーソルで行をまたいで伸びる", text: "abc\ndef\nghi\njkl",
      cursors: [[2, 2], [6, 6]],
      steps: [
        .init(
          action: .command("cursorDownSelect"), text: "abc\ndef\nghi\njkl",
          cursors: [[2, 6], [6, 10]]),
        .init(
          action: .command("cursorDownSelect"), text: "abc\ndef\nghi\njkl", cursors: [[2, 14]]),
        .init(action: .command("cursorUpSelect"), text: "abc\ndef\nghi\njkl", cursors: [[2, 10]]),
      ]),
    .init(
      name: "⇧⌥←→ は全カーソルで語の単位に伸びる", text: "foo bar baz\nqux quux",
      cursors: [[5, 5], [17, 17]],
      steps: [
        .init(
          action: .command("cursorWordEndRightSelect"), text: "foo bar baz\nqux quux",
          cursors: [[5, 7], [17, 20]]),
        .init(
          action: .command("cursorWordEndRightSelect"), text: "foo bar baz\nqux quux",
          cursors: [[5, 11], [17, 20]]),
        .init(
          action: .command("cursorWordLeftSelect"), text: "foo bar baz\nqux quux",
          cursors: [[5, 8], [17, 16]]),
        .init(
          action: .command("cursorWordLeftSelect"), text: "foo bar baz\nqux quux",
          cursors: [[5, 4], [17, 12]]),
        .init(
          action: .command("cursorWordLeftSelect"), text: "foo bar baz\nqux quux",
          cursors: [[5, 0], [17, 8]]),
      ]),
    .init(
      name: "⌘←→ は全カーソルで行頭と行末へ動く", text: "  abc\ndef\n\tgh",
      cursors: [[4, 4], [8, 8], [12, 12]],
      steps: [
        .init(
          action: .command("cursorHome"), text: "  abc\ndef\n\tgh",
          cursors: [[2, 2], [6, 6], [11, 11]]),
        .init(
          action: .command("cursorHome"), text: "  abc\ndef\n\tgh",
          cursors: [[0, 0], [6, 6], [10, 10]]),
        .init(
          action: .command("cursorEnd"), text: "  abc\ndef\n\tgh",
          cursors: [[5, 5], [9, 9], [13, 13]]),
        .init(
          action: .command("cursorHomeSelect"), text: "  abc\ndef\n\tgh",
          cursors: [[5, 2], [9, 6], [13, 11]]),
      ]),
    .init(
      name: "写した選択は同じ数のカーソルへ 1 つずつ配られる", text: "a-1\nb\n2 c d e",
      cursors: [[0, 1], [4, 7]],
      steps: [
        .init(
          action: .copy, text: "a-1\nb\n2 c d e", cursors: [[0, 1], [4, 7]],
          clipboard: .init(text: "a\nb\n2", pieces: ["a", "b\n2"], entireLine: false)),
        .init(
          action: .command("cursorEnd"), text: "a-1\nb\n2 c d e", cursors: [[3, 3], [13, 13]]),
        .init(action: .paste, text: "a-1a\nb\n2 c d eb\n2", cursors: [[4, 4], [17, 17]]),
      ]),
    .init(
      name: "写した選択は数の違うカーソルへは全体が入る", text: "ab cd\nx y z",
      cursors: [[0, 2], [3, 5]],
      steps: [
        .init(
          action: .copy, text: "ab cd\nx y z", cursors: [[0, 2], [3, 5]],
          clipboard: .init(text: "ab\ncd", pieces: ["ab", "cd"], entireLine: false)),
        .init(action: .command("cursorDown"), text: "ab cd\nx y z", cursors: [[8, 8], [11, 11]]),
        .init(action: .type("_"), text: "ab cd\nx _y z_", cursors: [[9, 9], [13, 13]]),
        .init(action: .paste, text: "ab cd\nx _aby z_cd", cursors: [[11, 11], [17, 17]]),
      ]),
    .init(
      name: "写した中身に改行があっても配り方は崩れない", text: "a\nb c\nd\n12",
      cursors: [[0, 3], [4, 7]],
      steps: [
        .init(
          action: .copy, text: "a\nb c\nd\n12", cursors: [[0, 3], [4, 7]],
          clipboard: .init(text: "a\nb\nc\nd", pieces: ["a\nb", "c\nd"], entireLine: false)),
        .init(action: .escape, text: "a\nb c\nd\n12", cursors: [[0, 3]]),
        .init(action: .escape, text: "a\nb c\nd\n12", cursors: [[3, 3]]),
        .init(action: .command("cursorDown"), text: "a\nb c\nd\n12", cursors: [[7, 7]]),
        .init(action: .command("cursorDown"), text: "a\nb c\nd\n12", cursors: [[9, 9]]),
        .init(
          action: .command("editor.action.addSelectionToNextFindMatch"), text: "a\nb c\nd\n12",
          cursors: [[8, 10]]),
        .init(action: .paste, text: "a\nb c\nd\na\nb\nc\nd", cursors: [[15, 15]]),
      ]),
    .init(
      name: "空のキャレットの列は行を 1 つずつ写し同じ行は 1 回", text: "line1\nline2\nline3",
      cursors: [[2, 2], [3, 3], [14, 14]],
      steps: [
        .init(
          action: .copy, text: "line1\nline2\nline3", cursors: [[2, 2], [3, 3], [14, 14]],
          clipboard: .init(
            text: "line1\n\nline3\n", pieces: ["line1\n", "line3\n"], entireLine: false)),
        .init(action: .escape, text: "line1\nline2\nline3", cursors: [[2, 2]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "line1\nline2\nline3",
          cursors: [[2, 2], [8, 8]]),
        .init(
          action: .paste, text: "liline1\nne1\nliline3\nne2\nline3", cursors: [[8, 8], [20, 20]]),
      ]),
    .init(
      name: "空のキャレットと選択が混ざれば行と選択を写す", text: "abc\ndef\nghi",
      cursors: [[1, 1], [4, 6]],
      steps: [
        .init(
          action: .copy, text: "abc\ndef\nghi", cursors: [[1, 1], [4, 6]],
          clipboard: .init(text: "abc\n\nde", pieces: ["abc\n", "de"], entireLine: false)),
        .init(action: .paste, text: "aabc\nbc\ndef\nghi", cursors: [[5, 5], [10, 10]]),
      ]),
    .init(
      name: "1 本のキャレットで写した行は全カーソルの行の上へ入る", text: "ab\ncd\nef",
      cursors: [[1, 1]],
      steps: [
        .init(
          action: .copy, text: "ab\ncd\nef", cursors: [[1, 1]],
          clipboard: .init(text: "ab\n", pieces: nil, entireLine: true)),
        .init(action: .command("cursorDown"), text: "ab\ncd\nef", cursors: [[4, 4]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "ab\ncd\nef",
          cursors: [[4, 4], [7, 7]]),
        .init(action: .paste, text: "ab\nab\ncd\nab\nef", cursors: [[7, 7], [13, 13]]),
      ]),
    .init(
      name: "1 本の選択を写すと行の数が合えば配られる", text: "1\n2\n3\nab\ncd\nef",
      cursors: [[0, 5]],
      steps: [
        .init(
          action: .copy, text: "1\n2\n3\nab\ncd\nef", cursors: [[0, 5]],
          clipboard: .init(text: "1\n2\n3", pieces: nil, entireLine: false)),
        .init(action: .command("cursorDown"), text: "1\n2\n3\nab\ncd\nef", cursors: [[7, 7]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "1\n2\n3\nab\ncd\nef",
          cursors: [[7, 7], [10, 10]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "1\n2\n3\nab\ncd\nef",
          cursors: [[7, 7], [10, 10], [13, 13]]),
        .init(
          action: .paste, text: "1\n2\n3\na1b\nc2d\ne3f", cursors: [[8, 8], [12, 12], [16, 16]]),
      ]),
    .init(
      name: "外から写した行は数が合えば 1 行ずつ配られる", text: "x y z",
      cursors: [[1, 1], [3, 3], [5, 5]],
      steps: [
        .init(
          action: .pasteExternal("1\n2\n3\n"), text: "x1 y2 z3",
          cursors: [[2, 2], [5, 5], [8, 8]])
      ]),
    .init(
      name: "外から写した CRLF の行も配られる", text: "x y",
      cursors: [[1, 1], [3, 3]],
      steps: [
        .init(action: .pasteExternal("1\r\n2\r\n"), text: "x1 y2", cursors: [[2, 2], [5, 5]])
      ]),
    .init(
      name: "外から写した行の数が違えば全体が入る", text: "x y z",
      cursors: [[1, 1], [3, 3], [5, 5]],
      steps: [
        .init(
          action: .pasteExternal("1\n2\n"), text: "x1\n2\n y1\n2\n z1\n2\n",
          cursors: [[5, 5], [11, 11], [17, 17]])
      ]),
    .init(
      name: "外から写した末尾の改行は 1 つだけ除いて数える", text: "x y",
      cursors: [[1, 1], [3, 3]],
      steps: [
        .init(
          action: .pasteExternal("1\n2\n\n"), text: "x1\n2\n\n y1\n2\n\n",
          cursors: [[6, 6], [13, 13]])
      ]),
    .init(
      name: "配る行が空のカーソルも他のカーソルが入れた分だけずれる", text: "x y",
      cursors: [[1, 1], [3, 3]],
      steps: [
        .init(action: .pasteExternal("1\n\n"), text: "x1 y", cursors: [[2, 2], [3, 3]])
      ]),
    .init(
      name: "カットは全選択を消して写し、同じ数へ配る", text: "ab x cd y",
      cursors: [[0, 2], [5, 7]],
      steps: [
        .init(
          action: .cut, text: " x  y", cursors: [[0, 0], [3, 3]],
          clipboard: .init(text: "ab\ncd", pieces: ["ab", "cd"], entireLine: false)),
        .init(action: .paste, text: "ab x cd y", cursors: [[2, 2], [7, 7]]),
      ]),
    .init(
      name: "空のキャレットの列のカットは行を消して写す", text: "ab\ncd\nef\ngh",
      cursors: [[1, 1], [7, 7]],
      steps: [
        .init(
          action: .cut, text: "cd\ngh", cursors: [[0, 0], [3, 3]],
          clipboard: .init(text: "ab\n\nef\n", pieces: ["ab\n", "ef\n"], entireLine: false)),
        .init(action: .paste, text: "ab\ncd\nef\ngh", cursors: [[3, 3], [9, 9]]),
      ]),
    .init(
      name: "⌥⌘↓ が写した選択が重なればまとまる", text: "abc\ndef\nghi",
      cursors: [[1, 5]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abc\ndef\nghi",
          cursors: [[1, 5], [5, 9]]),
        .init(
          action: .command("editor.action.insertCursorBelow"), text: "abc\ndef\nghi",
          cursors: [[1, 5], [5, 9]]),
      ]),
    .init(
      name: "重なった選択は最後に足したカーソルの向きに倣う", text: "abcd\nabcd",
      cursors: [[3, 1], [6, 8]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "abcd\nabcd",
          cursors: [[1, 3], [6, 8]]),
        .init(action: .escape, text: "abcd\nabcd", cursors: [[1, 3]]),
      ]),
    .init(
      name: "重なった選択は最後に足したのでなければ先にあった向きを保つ", text: "abcd\nabcd\nxy",
      cursors: [[3, 1], [6, 8], [12, 12]],
      steps: [
        .init(
          action: .command("editor.action.insertCursorAbove"), text: "abcd\nabcd\nxy",
          cursors: [[3, 1], [6, 8], [12, 12]]),
        .init(action: .escape, text: "abcd\nabcd\nxy", cursors: [[3, 1]]),
      ]),
    .init(
      name: "⇧→ で接した選択はまとまらず重なればまとまる", text: "abcd",
      cursors: [[0, 1], [2, 3]],
      steps: [
        .init(action: .command("cursorRightSelect"), text: "abcd", cursors: [[0, 2], [2, 4]]),
        .init(action: .command("cursorRightSelect"), text: "abcd", cursors: [[0, 4]]),
      ]),
  ]

  static let limits: [LimitCase] = [
    .init(
      name: "⌘⇧L は上限で後ろから切り押した場所の出現を主に残す", unit: "a ", count: 10005, caret: 20008,
      actions: [.command("editor.action.selectHighlights")], cursorCount: 10000,
      primary: [20008, 20009], last: [19998, 19999]),
    .init(
      name: "⌥⌘↓ は上限を越えて足さない", unit: "ab\n", count: 10005, caret: 1,
      actions: [.command("editor.action.selectHighlights")] + [
        .command("editor.action.insertCursorBelow")
      ], cursorCount: 5001,
      primary: [0, 2], last: [15000, 15002]),
    .init(
      name: "⌘U は 50 段まで戻す", unit: "a", count: 60, caret: 0,
      actions: Array(repeating: .command("cursorRight"), count: 52)
        + Array(repeating: .command("cursorUndo"), count: 51), cursorCount: 1,
      primary: [2, 2], last: [2, 2]),
  ]
}
// swiftlint:enable type_body_length
