import Foundation
import OrbeEditorCore

/// 移動の種類。意味は VS Code の同じ役のコマンド（→ `EditCommands.move`）。
enum Movement: Equatable, Sendable {
  case left, right, up, down
  case wordLeft, wordRight
  /// 最初の非空白 ⇄ 1 列目（VS Code の `cursorHome`）。
  case home
  case end
  /// 1 列目（⌃A）。
  case lineStart
  /// 行末（⌃E）。
  case lineEnd
  case paragraphBackward, paragraphForward
  case documentStart, documentEnd
  case pageUp, pageDown
}

enum CaseChange: Sendable {
  case upper, lower, capitalize
}

/// 標準のセレクタが写る編集のコマンド。
enum EditCommand: Equatable, Sendable {
  case move(Movement, extending: Bool)
  case selectAll, selectLine, selectWord
  /// 打鍵（選択を置き換えて入れる）。
  case insert(String)
  /// 改行。`indents` なら今の行の字下げ（キャレットより左の空白）を引き継ぐ。
  case newline(indents: Bool)
  case tab, backtab, indent
  /// タブ文字を入れる（⌥⇥）。
  case literalTab
  case deleteBackward, deleteForward, deleteBackwardDecomposing
  case deleteWordBackward, deleteWordForward
  /// 選択だけを消す（選択が無ければ何もしない）。
  case deleteSelection
  /// 行頭まで（1 列目なら前の改行）。
  case deleteToLineStart
  /// 行末まで（行末なら改行）。
  case deleteToLineEnd
  /// ⌃K（前へ）と、行頭までのキル（後ろへ）。消した文字列をキルバッファへ入れる。
  case kill(forward: Bool)
  case yank
  case transpose, transposeWords
  case changeCase(CaseChange)
  case setMark, selectToMark, deleteToMark, swapWithMark
  case centerSelection
  /// `range` を置き換える（IME が変換の外で範囲を指して入れた——長押しのアクセントなど）。前後で区切る。
  case replace(NSRange, String)
  /// 貼る（改行は文書の作法へ揃える）。`entireLine` は行ごと写した印——選択が空で文字列の改行が末尾の 1 つだけなら、
  /// キャレットの行の上に行として入れる。前後で区切る。
  case paste(String, entireLine: Bool)
  /// 切り取る——選択を消す。選択が空なら行を消す（改行まで。最終行なら前の行の改行から）。
  case cut
  /// 落とした文字列を `offset` に入れて選ぶ（改行は文書の作法へ揃える）。`moving` があればその範囲を消す（同じ面の中の
  /// 移動。消すことと入れることは 1 つの束）。
  case drop(String, at: Int, moving: NSRange?)
}

/// 見せ方——コマンドの後にスクロールをどう置くか。
enum Reveal: Equatable, Sendable {
  case none
  /// 主のキャレットが見えるところまで最小限。
  case minimal
  /// 主のキャレットの行を中央へ。
  case center
  /// 行の数だけ送ってから、キャレットが見えるところまで最小限。
  case page(Int)
}

/// コマンドの読む環境。本文を読むのは写しだけ。
struct EditingEnvironment {
  let text: TextRope
  let geometry: any LineGeometry
  /// ページ送りの行の数（VS Code の `pageSize`——見えている行の数 − 2、1 以上）。
  let pageLines: Int
  let indentation: Indentation
  let lineBreak: LineBreak
  let killBuffer: String
}

/// コマンドの結果。`edits` は束の前の本文の座標、`state` のカーソルは束の後の本文の座標。
struct CommandResult {
  var state: EditState
  var edits = EditBatch.empty
  var undo = UndoKind.other
  var reveal = Reveal.minimal
  /// キルバッファへ入れる文字列（入れないなら nil）。
  var kill: String?
}

/// 編集の規則の入口（純関数）。本文の写し・編集の状態・環境から、編集の束・新しい状態・undo の種類・見せ方を返す。
/// AppKit・Metal に依らないので、窓も装置も無しに VS Code と突き合わせられる。
enum EditCommands {
  /// コマンドを実行する。「直前がキルだったか」はここ 1 か所で決める——キルバッファへ何かを入れたコマンドだけがキル（何も
  /// しなかったキルやマークへの削除は数えない）。
  static func run(_ command: EditCommand, _ state: EditState, _ env: EditingEnvironment)
    -> CommandResult
  {
    var result = result(of: command, state, env)
    result.state.lastWasKill = result.kill != nil
    return result
  }

  private static func result(
    of command: EditCommand, _ state: EditState, _ env: EditingEnvironment
  ) -> CommandResult {
    switch command {
    case .move(let movement, let extending):
      return move(movement, extending: extending, state, env)
    case .selectAll:
      let cursor = Cursor.selecting(NSRange(location: 0, length: env.text.length))
      return CommandResult(
        state: EditState(cursors: CursorList(cursor), mark: state.mark), reveal: .none)
    case .selectLine: return select(state, env) { lineSelection($0, env.text) }
    case .selectWord: return select(state, env) { wordSelection(at: $0.position, env.text) }
    case .insert(let string): return type(string, state, env)
    case .newline(let indents): return newline(indents: indents, state, env)
    case .tab: return tab(state, env)
    case .backtab: return shift(outdent: true, state, env)
    case .indent: return shift(outdent: false, state, env)
    case .literalTab: return replaceSelections(with: "\t", undo: .typing(.other), state, env)
    case .deleteBackward: return deleteBackward(state, env)
    case .deleteForward: return deleteForward(state, env)
    case .deleteBackwardDecomposing: return deleteDecomposing(state, env)
    case .deleteWordBackward: return delete(state, env) { deleteWordLeftRange($0, env.text) }
    case .deleteWordForward: return delete(state, env) { deleteWordRightRange($0, env.text) }
    case .deleteSelection: return delete(state, env) { $0.selection }
    case .deleteToLineStart: return delete(state, env) { lineStartRange($0, env.text) }
    case .deleteToLineEnd: return delete(state, env) { lineEndRange($0, env.text) }
    case .kill(let forward): return kill(forward: forward, state, env)
    case .yank: return replaceSelections(with: env.killBuffer, undo: .other, state, env)
    case .transpose: return transpose(state, env)
    case .transposeWords: return transposeWords(state, env)
    case .changeCase(let change): return changeCase(change, state, env)
    case .setMark, .selectToMark, .deleteToMark, .swapWithMark:
      return mark(command, state, env)
    case .centerSelection:
      return CommandResult(
        state: EditState(cursors: state.cursors, mark: state.mark), reveal: .center)
    case .replace(let range, let string):
      return edit(state, env, undo: .other) {
        $0 == state.cursors.primary ? Replacement(range, string) : nil
      }
    case .paste(let string, let entireLine):
      return paste(string, entireLine: entireLine, state, env)
    case .cut: return cut(state, env)
    case .drop(let string, let offset, let moving):
      return drop(string, at: offset, moving: moving, state, env)
    }
  }

  /// カーソルごとに選び直す（編集しない）。
  static func select(
    _ state: EditState, _ env: EditingEnvironment, _ transform: (Cursor) -> Cursor
  ) -> CommandResult {
    var cursors = state.cursors.map(transform)
    cursors.normalize()
    return CommandResult(state: EditState(cursors: cursors, mark: state.mark))
  }
}
