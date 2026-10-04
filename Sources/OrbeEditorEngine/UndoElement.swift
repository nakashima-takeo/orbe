import Foundation
import OrbeEditorCore

/// undo の要素 1 つ——最初の本文に当てる前向きの束、閉じたときに作る逆向きの束、前後のカーソルの列。
@MainActor
final class UndoElement {
  private(set) var forward: EditBatch
  private(set) var backward: EditBatch?
  private(set) var kind: UndoKind
  let before: CursorList
  private(set) var after: CursorList
  /// 要素の前の本文（閉じるまで。逆向きの束を作るのに使う）。
  private var base: TextRope?

  init(base: TextRope, forward: EditBatch, kind: UndoKind, before: CursorList, after: CursorList) {
    self.base = base
    self.forward = forward
    self.kind = kind
    self.before = before
    self.after = after
  }

  /// まとまりの続きの束を合成する。`result` は束を当てた後の本文。
  func append(_ batch: EditBatch, result: TextRope, kind: UndoKind, after: CursorList) {
    forward = forward.then(batch, result: result)
    self.kind = kind
    self.after = after
  }

  func close() {
    guard let base else { return }
    backward = forward.inverse(of: base)
    self.base = nil
  }
}

extension EditBatch {
  /// 各編集の置換の中身（逆向きの束が置き換える、束の後の本文の中身）。
  var newRangesContent: [ContiguousArray<UInt16>] { edits.map(\.replacement) }
}
