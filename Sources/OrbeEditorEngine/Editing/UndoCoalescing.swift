/// 打鍵の種類（VS Code の `EditOperationType` の打鍵の 3 つ）。
enum Typing: Equatable, Sendable {
  case other, firstSpace, consecutiveSpace
}

/// undo の種類——前後の種類の組で、同じ undo の要素にまとめるか区切るかを決める。
enum UndoKind: Equatable, Sendable {
  case typing(Typing)
  /// Enter（前で区切り、後に続けて打った字は同じまとまり）。
  case newline
  case deletingLeft
  case deletingRight
  /// 前後で区切る編集（語の削除・行末までの削除・キル・ヤンク・入れ替え・大小文字・字下げ・丸ごと置き換え）。
  case other
}

/// undo のまとめ方（VS Code の `shouldPushStackElementBetween` と削除の規則）。純関数。
enum UndoCoalescing {
  /// コマンドが返した種類を、直前の種類に続けたときの種類にする——空白は、直前が空白なら「続く空白」。
  static func resolve(_ kind: UndoKind, after previous: UndoKind?) -> UndoKind {
    guard kind == .typing(.firstSpace) else { return kind }
    switch previous {
    case .typing(.firstSpace)?, .typing(.consecutiveSpace)?: return .typing(.consecutiveSpace)
    default: return kind
    }
  }

  /// 直前の種類 `previous`（無ければ要素が開いていない）の後に `next` を積むとき、新しい要素を始めるか。`joinsLines` は
  /// 削除が行を結合するか。
  static func startsNewElement(
    after previous: UndoKind?, _ next: UndoKind, joinsLines: Bool
  ) -> Bool {
    guard let previous, previous != .other, next != .other, next != .newline else { return true }
    if joinsLines { return true }
    switch (previous, next) {
    case (.deletingLeft, .deletingLeft), (.deletingRight, .deletingRight):
      return false
    case (.typing(.firstSpace), .typing):
      return false
    case (.typing(let a), .typing(let b)):
      return group(a) != group(b)
    case (.newline, .typing(let b)):
      return group(b) != group(.other)
    default:
      return true
    }
  }

  /// VS Code の `normalizeOperationType`——空白の 2 つは同じ組。
  private static func group(_ typing: Typing) -> Int {
    typing == .other ? 0 : 1
  }
}
