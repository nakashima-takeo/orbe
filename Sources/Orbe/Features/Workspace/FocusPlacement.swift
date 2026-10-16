import SwiftUI

/// フォームが focus を置いた欄に、選択（キャレット）を宣言する。
///
/// AppKit は focus が入った field editor を全選択するので、focus を代入するのと同じ更新で書いた選択はそれに負ける。
/// そこで、置く欄を記録し、focus がその欄へ移った変化を受けてから宣言する。記録は focus のどの変化でも消すので、
/// クリックなどフォームが置いたのではない focus の変化では宣言しない（クリックした位置が残る）。
///
/// 選択の束縛は欄ごとの真実ではなく、ウィンドウで共有する 1 つの field editor の選択を写すだけで、別の欄の選択
/// （この欄の文字列には範囲外の添字）も書き込まれうる。そのため束縛は TextField へ渡す書くだけの口とし、view から読まない。
/// 束縛した欄の中身をモデルの側から差し替えると古い選択が残るので、差し替えたら `place` で宣言し直す。
struct FocusPlacement<Field: Hashable> {
  /// ⇥ / ⇧⇥ で巡る欄の順序。
  let order: [Field]
  private var pending: Field?
  private var selections: [Field: TextSelection] = [:]

  init(order: [Field]) { self.order = order }

  /// `TextField(text:selection:)` へ渡す口。
  subscript(selection field: Field) -> TextSelection? {
    get { selections[field] }
    set { selections[field] = newValue }
  }

  /// `field` へ focus を置く。すでに focus があれば、その場で宣言する。
  /// - Parameter caretAtEnd: 末尾にキャレットを宣言する欄の文字列。nil の欄は宣言しない（AppKit の全選択のまま）。
  mutating func place(
    _ field: Field, focus: FocusState<Field?>.Binding, caretAtEnd: (Field) -> String?
  ) {
    if focus.wrappedValue == field {
      declare(field, caretAtEnd: caretAtEnd)
    } else {
      pending = field
      focus.wrappedValue = field
    }
  }

  /// `order` で今の欄の次（`forward`）か前の欄へ focus を置く。
  mutating func cycle(
    forward: Bool, focus: FocusState<Field?>.Binding, caretAtEnd: (Field) -> String?
  ) {
    guard let current = focus.wrappedValue, let index = order.firstIndex(of: current) else {
      return
    }
    let next = order[(index + (forward ? 1 : order.count - 1)) % order.count]
    place(next, focus: focus, caretAtEnd: caretAtEnd)
  }

  /// focus の変化を渡す（`onChange(of: focus)`）。置いた欄へ移ったときだけ宣言する。
  mutating func focusDidChange(to field: Field?, caretAtEnd: (Field) -> String?) {
    defer { pending = nil }
    guard let field, field == pending else { return }
    declare(field, caretAtEnd: caretAtEnd)
  }

  private mutating func declare(_ field: Field, caretAtEnd: (Field) -> String?) {
    guard let text = caretAtEnd(field) else { return }
    selections[field] = TextSelection(insertionPoint: text.endIndex)
  }
}
