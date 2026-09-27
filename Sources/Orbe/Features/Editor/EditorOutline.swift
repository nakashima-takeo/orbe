import Foundation
import OrbeEditorCore

/// エクスプローラーの下段のアウトラインの状態（pane ごと）——見せている文書の結果（位置の無い面）・見えている行・選択・
/// 畳み・絞り込み・状態。SwiftUI と行の列はこれだけを読み、文書を直接観測しない。本文への飛び方（選択・スクロール・焦点）は
/// 閉包で pane へ戻す。
///
/// main の仕事は見えている行と畳んだ数にだけ比例する——行はシンボルの番号から二分探索で引き（`OutlineRows`）、結果を
/// 受け取るときと開閉のときは、畳んだシンボルの鍵を結果の「鍵 → 番号」の表で引き直すだけ。畳みは文書ごとにアプリの実行中
/// だけ持つ（VS Code と同じく永続しない）。選択はシンボルの番号 1 つで、カーソル追従と ↑↓ が同じ 1 つを動かす。
@MainActor @Observable
final class EditorOutline {
  /// 見せるもの。
  enum Status: Equatable {
    /// 焦点の文書が無い・言語がアウトラインを出せない。
    case unavailable
    /// 取り出し中。
    case loading
    /// シンボルが無い。
    case empty
    case ready
  }

  /// 本文への飛び方。
  enum Jump {
    /// 名前の頭へキャレットを置く（焦点はアウトラインに残る。単クリック）。
    case name
    /// 名前の頭へキャレットを置き、焦点を本文へ（Enter）。
    case nameAndFocus
    /// 範囲全体を選び、焦点を本文へ（ダブルクリック）。
    case range
  }

  /// 選択（シンボルの番号）。選び直すたびに通し番号が進み、行の列はそれを見て選んだ行を見せる（同じシンボルを選び
  /// 直しても送る。行の番号がずれただけでは送らない）。
  struct Selection: Hashable {
    let symbol: Int
    let serial: Int
  }

  /// 単クリックから飛ぶまで（ダブルクリックを待つ）と、キャレットが止んでから追従するまで。
  static let clickDelay: TimeInterval = 0.15
  static let followDelay: TimeInterval = 0.15
  /// 取り出し中の文言を出すまで（すぐ届けば出さない）。
  static let loadingDelay: TimeInterval = 0.05

  private(set) var status = Status.unavailable
  /// 取り出し中の文言を出している。
  private(set) var showsLoading = false
  /// 見せている文書の名前（文言が使う）。
  private(set) var documentName = ""
  /// 見えている行が変わるたびに進む（行の列はこれを見て読み直す）。
  private(set) var rowsVersion = 0
  private(set) var rowCount = 0
  private(set) var selection: Selection?
  /// 選んだ行を、見えていなければ中央へ寄せる（カーソル追従）。偽なら最小限だけ送る（↑↓）。
  @ObservationIgnored private(set) var revealsCentered = false
  /// 絞り込みの文字列と、入力欄を出しているか。
  private(set) var filterText = ""
  private(set) var isFilterShown = false
  /// すべて折りたたんだまま、どれも開いていない（見出しの切り替えが「すべて展開」になる）。
  private(set) var isAllCollapsed = false

  /// 本文へ飛ぶ（シンボルの番号・結果の印・飛び方）。
  @ObservationIgnored var onJump: (Int, OutlineToken, Jump) -> Void = { _, _, _ in }
  @ObservationIgnored let clickDelay = EditorDelay()
  @ObservationIgnored let followDelay = EditorDelay()
  @ObservationIgnored let loadingDelay = EditorDelay()
  @ObservationIgnored private weak var document: EditorDocument?
  @ObservationIgnored private(set) var outline: DocumentOutline?
  @ObservationIgnored private var filter: OutlineFilterResult?
  @ObservationIgnored private(set) var rows = OutlineRows.empty
  @ObservationIgnored private var folds: [URL: Folds] = [:]
  @ObservationIgnored private var selectionSerial = 0

  /// 文書ごとの畳み。すべて折りたたんだ後は、開いたものを覚える。
  private struct Folds {
    var collapseAll = false
    var keys: Set<OutlineKey> = []
  }

  /// 1 行の中身。
  struct Row: Equatable {
    let symbol: Int
    let name: String
    let kind: OutlineKind
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    /// 絞り込みで一致した字の区間（UTF-16）。
    let matches: [Range<Int>]
  }

  // MARK: - 文書

  /// 見せる文書を替える（nil なら無し）。絞り込みは解く（VS Code と同じ）。
  func bind(_ document: EditorDocument?) {
    guard document !== self.document else { return }
    self.document?.filterOutline("")
    self.document = document
    filterText = ""
    isFilterShown = false
    selection = nil
    clickDelay.cancel()
    followDelay.cancel()
    documentName = document?.url.lastPathComponent ?? ""
    outlineDidChange()
  }

  /// 文書の結果か絞り込みが変わった（か、結び直した）。畳みと選択を新しい結果の番号で引き直し、キャレットへ追従する。
  func outlineDidChange() {
    guard let document, document.supportsOutline else {
      setOutline(nil, filter: nil, status: .unavailable)
      return
    }
    guard let outline = document.outline else {
      setOutline(nil, filter: nil, status: .loading)
      return
    }
    let previous = selection.flatMap { self.outline?.symbols[$0.symbol].key }
    setOutline(
      outline, filter: document.outlineFilter, status: outline.symbols.isEmpty ? .empty : .ready)
    if let symbol = previous.flatMap(outline.index(of:)) {
      selection = Selection(symbol: symbol, serial: selection?.serial ?? 0)
    }
    reindex()
    follow()
  }

  private func setOutline(
    _ outline: DocumentOutline?, filter: OutlineFilterResult?, status: Status
  ) {
    let token = self.outline?.token
    self.outline = outline
    self.filter = filter
    if outline?.token != token { selection = nil }
    if status != self.status { self.status = status }
    if status == .loading {
      loadingDelay.run(after: Self.loadingDelay) { [weak self] in
        guard let self, self.status == .loading else { return }
        showsLoading = true
      }
    } else {
      loadingDelay.cancel()
      if showsLoading { showsLoading = false }
    }
    if outline == nil { reindex() }
  }

  /// 見えている行を数え直す（畳んだ鍵を今の結果の番号へ引き直す）。
  private func reindex() {
    guard let outline, let document else {
      rows = .empty
      publishRows()
      return
    }
    let folds = folds[document.url] ?? Folds()
    let indices = folds.keys.compactMap(outline.index(of:))
    rows = OutlineRows(
      outline: outline, filter: filter,
      folding: folds.collapseAll
        ? .allExcept(Set(indices)) : .collapsed(indices.filter(outline.hasChildren).sorted()))
    isAllCollapsed = folds.collapseAll && folds.keys.isEmpty
    if let selection, !rows.includes(selection.symbol) { self.selection = nil }
    publishRows()
  }

  private func publishRows() {
    rowCount = rows.count
    rowsVersion &+= 1
  }

  /// 選んでいる行（畳まれていれば nil）。
  var selectedRow: Int? { selection.flatMap { rows.row(of: $0.symbol) } }

  /// 選択の行の番号（行の列が引く）。
  func row(of selection: Selection) -> Int? { rows.row(of: selection.symbol) }

  /// シンボルを選び、その行を見せる。
  private func choose(_ symbol: Int, centered: Bool) {
    selectionSerial &+= 1
    revealsCentered = centered
    selection = Selection(symbol: symbol, serial: selectionSerial)
  }

  /// `index` 番目の見えている行。
  func row(at index: Int) -> Row {
    let symbol = rows.symbol(at: index)
    let face = outline!.symbols[symbol]
    let hasChildren = rows.hasChildren(symbol)
    return Row(
      symbol: symbol, name: face.name, kind: face.kind, depth: face.depth,
      hasChildren: hasChildren, isExpanded: hasChildren && !isCollapsed(symbol),
      matches: filter?.matches[symbol] ?? [])
  }

  // MARK: - 畳み

  private func isCollapsed(_ symbol: Int) -> Bool {
    guard let outline, let document else { return false }
    let folds = folds[document.url] ?? Folds()
    return folds.collapseAll != folds.keys.contains(outline.symbols[symbol].key)
  }

  /// シンボルを開く・畳む。
  func setExpanded(_ symbol: Int, _ expanded: Bool) {
    guard let outline, let document, isCollapsed(symbol) == expanded else { return }
    var folds = folds[document.url] ?? Folds()
    let key = outline.symbols[symbol].key
    if folds.keys.contains(key) { folds.keys.remove(key) } else { folds.keys.insert(key) }
    self.folds[document.url] = folds
    reindex()
  }

  /// すべて折りたたむ（どれも開いていなければ、すべて展開する）。
  func toggleCollapseAll() {
    guard let document else { return }
    folds[document.url] = isAllCollapsed ? Folds() : Folds(collapseAll: true)
    reindex()
    if let symbol = selection?.symbol, rows.row(of: symbol) != nil {
      choose(symbol, centered: false)
    }
  }

  // MARK: - 選択と操作（行の列から）

  func select(row: Int) {
    guard row >= 0, row < rowCount else { return }
    choose(rows.symbol(at: row), centered: false)
  }

  /// ↑↓: 選ぶだけ（開かない）。選んでいなければ端から。
  func moveSelection(by delta: Int) {
    guard rowCount > 0 else { return }
    let current = selectedRow ?? (delta > 0 ? -1 : rowCount)
    select(row: min(rowCount - 1, max(0, current + delta)))
  }

  /// ←: 開いていれば畳み、畳んでいれば（子が無ければ）親へ。
  func moveLeft() {
    guard let symbol = selection?.symbol, let outline else { return }
    if rows.hasChildren(symbol), !isCollapsed(symbol) {
      setExpanded(symbol, false)
      return
    }
    var parent = outline.symbols[symbol].parent
    while let current = parent {
      if let row = rows.row(of: current) { return select(row: row) }
      parent = outline.symbols[current].parent
    }
  }

  /// →: 畳んでいれば開き、開いていれば最初の子へ。
  func moveRight() {
    guard let symbol = selection?.symbol, rows.hasChildren(symbol) else { return }
    if isCollapsed(symbol) {
      setExpanded(symbol, true)
    } else if let row = rows.row(of: symbol) {
      select(row: row + 1)
    }
  }

  /// Space: 選んだシンボルを開閉する。
  func toggleSelection() {
    guard let symbol = selection?.symbol, rows.hasChildren(symbol) else { return }
    setExpanded(symbol, isCollapsed(symbol))
  }

  /// Enter: 名前へ飛び、焦点を本文へ。
  func activateSelection() {
    guard let symbol = selection?.symbol, let outline else { return }
    clickDelay.cancel()
    onJump(symbol, outline.token, .nameAndFocus)
  }

  /// Home / End: 先頭・末尾の行を選ぶ。
  func selectEdge(last: Bool) {
    guard rowCount > 0 else { return }
    select(row: last ? rowCount - 1 : 0)
  }

  /// 単クリック: シェブロンの上なら開閉し、それ以外は選んで、ダブルクリックを待ってから名前へ飛ぶ（焦点は残る）。
  func click(row: Int, onChevron: Bool) {
    guard row >= 0, row < rowCount, let outline else { return }
    let symbol = rows.symbol(at: row)
    if onChevron, rows.hasChildren(symbol) {
      setExpanded(symbol, isCollapsed(symbol))
      return
    }
    select(row: row)
    let token = outline.token
    clickDelay.run(after: Self.clickDelay) { [weak self] in self?.onJump(symbol, token, .name) }
  }

  /// ダブルクリック: 範囲全体を選び、焦点を本文へ。
  func doubleClick(row: Int) {
    guard row >= 0, row < rowCount, let outline else { return }
    clickDelay.cancel()
    select(row: row)
    onJump(rows.symbol(at: row), outline.token, .range)
  }

  // MARK: - カーソル追従

  /// 文書の選択が変わった。止んでから追従する。
  func caretDidMove() {
    followDelay.run(after: Self.followDelay) { [weak self] in self?.follow() }
  }

  /// キャレットを含む最も深いシンボルを選ぶ——祖先が畳まれていれば開き、列の中で見えていなければ中央へ寄せる。焦点は
  /// 奪わない。無ければ（絞り込みで落ちていれば）選択を外す。
  func follow() {
    guard let document, let outline else { return }
    guard
      let symbol = document.outlineSymbol(
        containing: document.surface.caretLocation, in: outline.token),
      rows.includes(symbol)
    else {
      selection = nil
      return
    }
    var ancestor = outline.symbols[symbol].parent
    while let current = ancestor {
      if isCollapsed(current) { setExpanded(current, true) }
      ancestor = outline.symbols[current].parent
    }
    choose(symbol, centered: true)
  }

  // MARK: - 絞り込み

  /// 入力欄を出す（最初の 1 字は入力欄が受ける）。
  func showFilter() {
    isFilterShown = true
  }

  /// 入力欄の文字列が変わった。照合は文書の裏の仕事が行い、揃ったら `outlineDidChange` が来る。
  func setFilterText(_ text: String) {
    guard text != filterText else { return }
    filterText = text
    isFilterShown = true
    document?.filterOutline(text)
  }

  /// Esc: 絞り込みを解いて入力欄を隠す。
  func clearFilter() {
    filterText = ""
    isFilterShown = false
    document?.filterOutline("")
  }
}
