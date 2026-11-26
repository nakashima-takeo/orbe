import AppKit
import OrbeEditorCore

/// 一覧の器に載せる 1 行の値。行の view は 1 つで、3 種類を描き分ける。
enum EditorItemListRow: Equatable {
  /// 見出しの行（選べない）。題・数・右端のキーの札。
  case heading(title: String, count: Int, key: String?)
  case file(File)
  /// 操作の行。題・右端のキーの札。選べない操作の行は、押せない姿で描く。
  case action(String, key: String? = nil)

  struct File: Equatable {
    let chip: FileChip
    let name: String
    /// 名前を斜体にする（仮の文書）。
    var isItalic = false
    /// 名前を弱い色にする。
    var isDimmed = false
    let directory: String
    /// 名前とディレクトリの後ろの札（「現在」「プレビュー」）。
    var tags: [String] = []
    var mark = Mark.none
    /// git の状態の字（無ければ出さない）。
    var badge: GitStatus.Badge?
    /// × の説明（ツールチップ）と、丸の意味（VoiceOver）。
    var closeLabel: String?
    var markLabel: String?
  }

  /// ファイルの行の右の印。「未保存」の丸と「ディスクが変わった」の丸は、印の枠をホバーしている間だけ × に替わる。
  enum Mark: Equatable {
    case none
    case close
    case unsaved
    case diskChanged
  }
}

extension EditorItemListRow.Mark {
  /// 文書の印（「ディスクが変わった」が立っていれば、未保存かどうかに依らずその印）。上のバーの今のファイルのボタン・一覧の
  /// 行・diff の見出しが、ここから導く。
  @MainActor init(_ document: EditorDocument) {
    if document.isDiskChanged {
      self = .diskChanged
    } else {
      self = document.isDirty ? .unsaved : .none
    }
  }
}

/// 一覧の中身の行の組。行の列は見えている行の番号でだけ問うので、持ち主の配列を写して持ち、番号から計算で答える。同一性から
/// 番号を引く手間は、行の数に比例しないこと（行の列は、更新のたびに選択の同一性から番号を引く）。
protocol EditorItemListRows {
  var count: Int { get }
  func row(at index: Int) -> EditorItemListRow
  /// 行の同一性（選べない行は nil）。
  func id(at index: Int) -> AnyHashable?
  func index(of id: AnyHashable) -> Int?
}

/// 下の案内の 1 つ（キーの札と文言）。
struct EditorItemListHint {
  let key: EditorKeyCap.Content
  let label: String
}

/// 一覧の中身（不変の値）。持ち主が変わるたびに、載せる側が作り直して器へ渡す。
struct EditorItemListContent {
  let rows: any EditorItemListRows
  /// 開いたときに選ぶ行。
  let initialSelection: AnyHashable?
  let hints: [EditorItemListHint]
}

/// 載せる側の口の答え——行を決めた後に、器を閉じるか、開いたままか、一覧へ戻るか。
enum EditorItemListOutcome {
  case close
  case stay
  case back
}

/// 一覧の器が、載せる側へ問う口。
@MainActor
protocol EditorItemListOwner: AnyObject {
  /// 今の一覧の中身（器が開くとき・詳細から戻るとき・持ち主が変わったときに呼ぶ）。
  func itemListContent() -> EditorItemListContent
  /// 行 `id` の詳細の中身（詳細を持たない・行が無くなったなら nil）。
  func itemListDetail(of id: AnyHashable) -> EditorItemListContent?
  /// 行 `id` を決めた（↵・行のクリック）。
  func itemListCommit(_ id: AnyHashable) -> EditorItemListOutcome
  /// 行 `id` の中の部品（×）を押した。器は開いたまま。
  func itemListPress(_ id: AnyHashable)
}

/// 一覧の器——上のバーの今の項目のボタンに付いて浮く一覧の、開閉・今の中身・詳細に入っている行・選択と、キーと閉じ方を
/// 1 か所に持つ。行は持ち続ける 1 本の行の列（`list`）が、今の中身の行の組から見えている行だけを描く。行の列から届く番号は、
/// 描いている中身で同一性に直してから載せる側の口へ渡す。器の状態を書くのは器だけで、位置と見え隠れとフォーカスの行き先は
/// 器を持つ pane が `onOpen` / `onClose` / `onResize` で受ける。
@MainActor @Observable
final class EditorItemList {
  private(set) var isOpen = false
  /// 今の中身（一覧か詳細）。
  private(set) var content: EditorItemListContent?
  @ObservationIgnored private(set) weak var owner: EditorItemListOwner?
  /// 詳細に入っている行と、入ったときのその行の番号（戻ったときに行が無くなっていれば、同じ位置の選べる行を選ぶ）。
  @ObservationIgnored private(set) var detail: (id: AnyHashable, index: Int)?
  @ObservationIgnored private(set) var selection: AnyHashable?
  @ObservationIgnored private var rowsVersion = 0
  /// 行の名前に充てる絵文字の字体（pane が配る）。
  @ObservationIgnored var emoji: NSFont?
  @ObservationIgnored private(set) lazy var list = RowList(
    source: EditorItemListSource(itemList: self), rowHeight: Theme.Layout.editorItemListRow,
    trailingSpace: false)
  /// 開いた（pane が器を出して置き、行の列へフォーカスを移す）。
  @ObservationIgnored var onOpen: () -> Void = {}
  /// 閉じた（引数は本体の行き先へフォーカスを戻すか）。
  @ObservationIgnored var onClose: (Bool) -> Void = { _ in }
  /// 行の数が変わった（pane が器の高さを置き直す）。
  @ObservationIgnored var onResize: () -> Void = {}
  /// 行の列へフォーカスを入れる要求（行の列が窓に載っていなければ、載った時点で当てる）。
  @ObservationIgnored private(set) var wantsFocus = false

  /// 下の案内。
  var hints: [EditorItemListHint] { content?.hints ?? [] }

  /// 行の数。
  var rowCount: Int { content?.rows.count ?? 0 }

  /// `owner` の一覧で開く。
  func open(_ owner: EditorItemListOwner) {
    guard !isOpen else { return }
    let content = owner.itemListContent()
    self.owner = owner
    detail = nil
    isOpen = true
    show(content, selecting: content.initialSelection)
    onOpen()
    if let selection { list.center(selection) }
  }

  /// 閉じる口。先に閉じた状態にしてから知らせる（知らせの中でフォーカスが動き、行の列がフォーカスを失った知らせで
  /// ここへ戻っても何もしない）。
  func close(_ dismissal: EditorDismissal) {
    guard isOpen else { return }
    isOpen = false
    owner = nil
    detail = nil
    selection = nil
    wantsFocus = false
    onClose(dismissal.returnsFocus)
  }

  /// 行の列へフォーカスを入れる（行の列が窓に載っていなければ、載った時点で当てる）。器を SwiftUI の中に載せる持ち主が、
  /// 開いた後に呼ぶ——行の列が窓に載る時点を、持ち主が決められないため。
  func requestFocus() {
    wantsFocus = true
    list.list.applyFocusRequest()
  }

  func focusRequestDidApply() {
    wantsFocus = false
  }

  /// 持ち主が変わった。詳細に入っていれば詳細の中身を引き直し、作れなければ一覧へ戻る。一覧なら一覧の中身を引き直す。選択は
  /// 同一性で保ち、無くなれば同じ位置の選べる行へ移す。
  func contentDidChange() {
    guard isOpen, let owner else { return }
    guard let detail else {
      show(owner.itemListContent(), keeping: selection)
      return
    }
    if let content = owner.itemListDetail(of: detail.id) {
      show(content, keeping: selection)
    } else {
      back(to: owner.itemListContent())
    }
  }

  // MARK: - キーと押下（行の列の源から）

  func perform(_ key: RowListKey.Action) {
    guard isOpen else { return }
    switch key {
    case .up: move(by: -1)
    case .down: move(by: 1)
    case .right: enterDetail()
    case .left: if detail != nil, let owner { back(to: owner.itemListContent()) }
    case .enter: if let selection { commit(selection) }
    case .escape: close(.escape)
    }
  }

  /// 行 `id` を決めた（↵・クリック）。
  func commit(_ id: AnyHashable) {
    guard isOpen, let owner else { return }
    selection = id
    reflectSelection()
    apply(owner.itemListCommit(id))
  }

  /// 行 `id` の中の部品を押した。
  func press(_ id: AnyHashable) {
    guard isOpen, let owner else { return }
    owner.itemListPress(id)
  }

  /// VoiceOver が行 `id` を選んだ。
  func select(_ id: AnyHashable) {
    selection = id
    reflectSelection()
  }

  /// 行の列のフォーカスが抜けた。
  func focusDidLeave() {
    close(.focusLeft)
  }

  // MARK: - 中身と選択

  private func apply(_ outcome: EditorItemListOutcome) {
    guard isOpen, let owner else { return }
    switch outcome {
    case .close: close(.owner)
    case .stay: break
    case .back: if detail != nil { back(to: owner.itemListContent()) }
    }
  }

  /// 選んでいる行の詳細に入る（載せる側が詳細の中身を作れたとき）。
  private func enterDetail() {
    guard detail == nil, let owner, let selection, let content,
      let index = content.rows.index(of: selection),
      let detailContent = owner.itemListDetail(of: selection)
    else { return }
    detail = (selection, index)
    show(detailContent, selecting: detailContent.initialSelection)
  }

  /// 詳細から一覧 `listContent` へ戻り、詳細に入っていた行を選ぶ（無くなっていれば同じ位置の選べる行）。
  private func back(to listContent: EditorItemListContent) {
    guard let detail else { return }
    self.detail = nil
    let rows = listContent.rows
    let selected =
      rows.index(of: detail.id) != nil ? detail.id : selectable(near: detail.index, in: rows)
    show(listContent, selecting: selected)
  }

  /// 中身を `next` に替え、選択 `kept` を同一性で保つ（無くなれば同じ位置の選べる行）。
  private func show(_ next: EditorItemListContent, keeping kept: AnyHashable?) {
    let oldIndex = kept.flatMap { id in content?.rows.index(of: id) }
    let selected: AnyHashable? =
      if let kept, next.rows.index(of: kept) != nil {
        kept
      } else {
        oldIndex.flatMap { selectable(near: $0, in: next.rows) } ?? next.initialSelection
      }
    show(next, selecting: selected)
  }

  private func show(_ next: EditorItemListContent, selecting selected: AnyHashable?) {
    let resized = next.rows.count != rowCount
    content = next
    selection = selected
    rowsVersion += 1
    reflectSelection()
    if resized { onResize() }
  }

  /// 選べる行の間で、選択を `step` だけ動かす（端で止まる）。選択が無ければ、端から最初の選べる行を選ぶ。
  private func move(by step: Int) {
    guard let rows = content?.rows, rows.count > 0 else { return }
    let start =
      selection.flatMap(rows.index(of:)).map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
    var index = start
    while index >= 0, index < rows.count {
      if let id = rows.id(at: index) {
        selection = id
        reflectSelection()
        return
      }
      index += step
    }
  }

  /// 番号 `index` に近い選べる行（その位置、無ければ下へ、無ければ上へ）。
  private func selectable(near index: Int, in rows: any EditorItemListRows) -> AnyHashable? {
    guard rows.count > 0 else { return nil }
    let start = min(index, rows.count - 1)
    for candidate in start..<rows.count { if let id = rows.id(at: candidate) { return id } }
    for candidate in stride(from: start - 1, through: 0, by: -1) {
      if let id = rows.id(at: candidate) { return id }
    }
    return nil
  }

  /// 行の版と選択を行の列へ写す。
  private func reflectSelection() {
    list.update(rowsVersion: rowsVersion, selection: selection, emoji: emoji, wantsFocus: false)
  }
}
