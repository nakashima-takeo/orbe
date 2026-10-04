import CoreGraphics
import Foundation
import OrbeEditorCore

/// カーソルを増やす・減らす規則（VS Code の `MultiCursorSelectionController`・`CursorMoveCommands.addCursorUp/Down`・
/// `removeSecondaryCursors`・`cancelSelection`）。何を探すかは Core の問い（`SearchQuestion`）、一致は Core の一致の規則。
extension EditCommands {
  /// ⌘D。続き（探している問い）が無く、カーソルが複数で選択がそろっていなければ（空の選択があるか、文字列が大小を無視して
  /// 違えば）、空のカーソルを語に広げて終わる。それ以外は主から続きを作り（主が空なら主を語にする）、最後に足したカーソルの
  /// 選択の終わりから次の一致を探して（末尾まで無ければ先頭へ回る）列の末尾に足す。足した一致が見えていなければ中央へ。
  static func addNextOccurrence(_ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    let text = env.text
    if state.continuation == nil, state.cursors.count > 1,
      SearchQuestion.of(state.cursors.selections, continuing: nil, in: text) == nil
    {
      var cursors = state.cursors.map { cursor in
        guard cursor.selection.length == 0, let word = regularWord(at: cursor.position, text)
        else { return cursor }
        return Cursor.selecting(word)
      }
      cursors.normalize()
      return CommandResult(state: EditState(cursors: cursors, mark: state.mark))
    }
    var next = state
    let match: NSRange
    if let question = state.continuation {
      guard
        let found = TextSearch.firstMatch(
          of: question.needle, in: text, rule: question.rule,
          from: NSMaxRange(state.cursors.last.selection))
      else { return CommandResult(state: state, reveal: .none) }
      match = found
    } else {
      guard let started = startSearch(state, text) else {
        return CommandResult(state: state, reveal: .none)
      }
      next.continuation = started.question
      if let word = started.word {
        match = word
      } else {
        guard
          let found = TextSearch.firstMatch(
            of: started.question.needle, in: text, rule: started.question.rule,
            from: NSMaxRange(state.cursors.last.selection))
        else { return CommandResult(state: next, reveal: .none) }
        match = found
      }
    }
    var cursors = CursorList(
      state.cursors.primary, others: state.cursors.others + [.selecting(match)])
    cursors.normalize()
    next.cursors = cursors
    return CommandResult(state: next, reveal: .showing(.centerIfOutside), revealing: match)
  }

  /// ⌘⇧L。続き（無ければ主から作った問い）の全一致を、上限なしで集めて選ぶ。押したときの主の選択に重なる（接するものを
  /// 含む）一致を主にし、無ければ最初の一致が主。列の上限で切れても主の一致は残る。一致が無ければ何もしない。
  static func selectAllOccurrences(_ state: EditState, _ env: EditingEnvironment)
    -> CommandResult
  {
    let text = env.text
    guard let question = state.continuation ?? startSearch(state, text)?.question else {
      return CommandResult(state: state, reveal: .none)
    }
    var next = state
    next.continuation = question
    var matches = TextSearch.matches(
      of: question.needle, in: text, rule: question.rule, limit: .max)
    guard !matches.isEmpty else { return CommandResult(state: next, reveal: .none) }
    let primary = state.cursors.primary.selection
    if let index = matches.firstIndex(where: {
      max($0.location, primary.location) <= min(NSMaxRange($0), NSMaxRange(primary))
    }) {
      matches.swapAt(0, index)
    }
    var cursors = CursorList(
      .selecting(matches[0]), others: matches.dropFirst().map { .selecting($0) })
    cursors.normalize()
    next.cursors = cursors
    return CommandResult(state: next, reveal: .none)
  }

  /// 主から続きを作る（VS Code の `MultiCursorSession.create`）——主が空なら主の語（無ければ作らない）を、そうでなければ主の
  /// 選択の文字列を探す。規則は、カーソルが 1 本で空のときだけ語の規則、それ以外は ⌘F の規則。主が空なら、主の語を最初の
  /// 一致として返す。
  private static func startSearch(_ state: EditState, _ text: TextRope) -> (
    question: SearchQuestion, word: NSRange?
  )? {
    let selection = state.cursors.primary.selection
    guard selection.length == 0 else {
      return (SearchQuestion(needle: text.substring(selection), rule: .find), nil)
    }
    guard let word = regularWord(at: selection.location, text) else { return nil }
    let rule: MatchRule = state.cursors.count == 1 ? .word : .find
    return (SearchQuestion(needle: text.substring(word), rule: rule), word)
  }

  /// ⌥⌘↑・⌥⌘↓。各カーソルの後ろに、選択の両端をそれぞれの覚えた横位置で 1 行上（下）へ写したカーソルを足す。先頭行の上・
  /// 最終行の下へは写さない（元と同じになり、まとまる）。いちばん上（下）のカーソルが見えるところまで最小限。
  static func insertCursor(below: Bool, _ state: EditState, _ env: EditingEnvironment)
    -> CommandResult
  {
    var added: [Cursor] = []
    added.reserveCapacity(state.cursors.count * 2)
    for cursor in state.cursors.all {
      added.append(cursor)
      added.append(translated(cursor, by: below ? 1 : -1, env))
    }
    guard var cursors = CursorList(added) else { return CommandResult(state: state) }
    cursors.normalize()
    let positions = cursors.all.map(\.position)
    let edge = (below ? positions.max() : positions.min()) ?? cursors.primary.position
    return CommandResult(
      state: EditState(cursors: cursors, mark: state.mark),
      revealing: NSRange(location: edge, length: 0))
  }

  /// カーソルを 1 行上下へ写したもの（VS Code の `MoveOperations.translateUp/Down`）。両端それぞれ、覚えた横位置（無ければ
  /// 今の x）にいちばん近い位置へ移り、その x を覚える。行の外へは出ない。
  private static func translated(_ cursor: Cursor, by lines: Int, _ env: EditingEnvironment)
    -> Cursor
  {
    let text = env.text
    func moved(_ offset: Int, desiredX: CGFloat?) -> (offset: Int, x: CGFloat?) {
      let row = text.row(containing: offset)
      let target = row + lines
      guard target >= 0, target < text.lineCount else { return (offset, desiredX) }
      let x =
        desiredX ?? env.geometry.x(ofColumn: offset - text.lineStart(row), row: row)
      return (text.lineStart(target) + env.geometry.column(atX: x, row: target), x)
    }
    let anchor = moved(cursor.anchor, desiredX: cursor.anchorDesiredX)
    let position = moved(cursor.position, desiredX: cursor.desiredX)
    return Cursor(
      selectionStart: NSRange(location: anchor.offset, length: 0), unit: .character,
      position: position.offset, desiredX: position.x, anchorDesiredX: anchor.x)
  }

  /// Esc。カーソルが複数なら主の 1 本（選択は保つ）、1 本で選択があれば動く端のキャレット。どちらでもなければ何もしない。
  static func cancel(_ state: EditState) -> CommandResult {
    let primary = state.cursors.primary
    if state.cursors.count > 1 {
      return CommandResult(state: EditState(cursors: CursorList(primary), mark: state.mark))
    }
    guard primary.hasSelection else { return CommandResult(state: state, reveal: .none) }
    return CommandResult(
      state: EditState(cursors: CursorList(Cursor(primary.position)), mark: state.mark))
  }
}
