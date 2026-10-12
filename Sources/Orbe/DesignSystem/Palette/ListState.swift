import Foundation

/// 一覧を見える所まで送る先。同じ行へ続けて送るとき（⌥↑↓ を続けて押す）も変化として届くよう、決めるたびに
/// 進む番号を持つ。
struct ListScrollTarget<ID: Hashable>: Equatable {
  let id: ID
  let serial: Int
}

/// 一覧 1 つの状態（絞り込みの文字・同一性での選択・最後の位置・送り先）と、それを動かす手続き。絞り込まない一覧は文字を
/// 使わない。選択は行の同一性で持ち、位置は付け直しのときだけ使う。選べる行の並びは、呼び出し側がその時点の行から渡す。
struct ListState<ID: Hashable> {
  /// 入力欄の文字（その一覧の絞り込み）。
  var query = ""
  private var selection = ModalSelection<ID?>(nil)
  /// 選択が最後に居た位置（選べる行の並びでの番号）。
  private var position = 0
  /// 一覧を送る先。人の操作のたびに今の選択で決め直す。付け直し（agent の変更）では決めない——人が流して
  /// 読んでいる一覧を、選んだ行の位置がずれただけで引き戻さないため。
  private(set) var scrollTarget: ListScrollTarget<ID>?

  var selectedID: ID? { selection.value }

  /// 実マウス移動（`MouseMovedDetector`）が `.pointer` へ落とす。
  var modality: InputModality {
    get { selection.modality }
    set { selection.modality = newValue }
  }

  /// 行が変わったあとの付け直し。同一性が今の行にあれば位置を覚え直し、無ければ覚えている位置（末尾で
  /// 頭打ち）の行へ移す。裏の変化はユーザーの意図ではないので入力モダリティは動かさない。
  mutating func reconcile(_ ids: [ID]) {
    if let id = selection.value, let index = ids.firstIndex(of: id) {
      position = index
    } else if ids.isEmpty {
      selection.restore(nil)
      position = 0
    } else {
      position = min(position, ids.count - 1)
      selection.restore(ids[position])
    }
  }

  /// ↑↓。端で巡回する。
  mutating func move(_ direction: Int, in ids: [ID]) {
    guard !ids.isEmpty else { return }
    let current = selection.value.flatMap { ids.firstIndex(of: $0) } ?? position
    select(at: (current + direction + ids.count) % ids.count, in: ids)
  }

  /// 先頭（direction < 0）か末尾へ。
  mutating func jump(_ direction: Int, in ids: [ID]) {
    guard !ids.isEmpty else { return }
    select(at: direction < 0 ? 0 : ids.count - 1, in: ids)
  }

  /// 同一性で選んで送る。今の行に無ければ何もせず false。
  @discardableResult mutating func select(_ id: ID, in ids: [ID]) -> Bool {
    guard let index = ids.firstIndex(of: id) else { return false }
    select(at: index, in: ids)
    return true
  }

  /// ホバー開始による選択の追従（実マウス移動の後だけ効く）。
  mutating func hoverSelect(_ id: ID, in ids: [ID]) {
    guard let index = ids.firstIndex(of: id) else { return }
    selection.hoverSelect(id)
    position = index
    follow()
  }

  /// 先頭の行を選ぶ（行が無ければ選択なし）。入力が変わったとき。
  mutating func selectFirst(in ids: [ID]) {
    if ids.isEmpty {
      selection.value = nil
      position = 0
    } else {
      select(at: 0, in: ids)
    }
  }

  /// 同一性を捨てる。次の付け直しで、同じ位置の行へ移る。
  mutating func forget() {
    selection.restore(nil)
  }

  /// 今の選択を送り先にする。
  mutating func follow() {
    guard let id = selection.value else { return }
    scrollTarget = ListScrollTarget(id: id, serial: (scrollTarget?.serial ?? 0) &+ 1)
  }

  private mutating func select(at index: Int, in ids: [ID]) {
    selection.value = ids[index]
    position = index
    follow()
  }
}
