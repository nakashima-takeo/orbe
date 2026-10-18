import AppKit

/// 行の列（`RowList`）の源。行の数・行の高さ・行の中身・操作の意味を答える。列は見えている行の枠（行の view）だけを持ち、
/// 行を番号で源に問うて描かせる。選択は源（model）が持ち、列は操作を渡すだけで自分では動かさない。
///
/// 行の組（`Rows`）は列が読み直すたびに写し、次に読み直すまでの問いと操作はすべてその写しで渡す——源の組が差し替わってから
/// 列が読み直すまでの間に押しても、見えている行に当たる。
@MainActor
protocol RowListSource: AnyObject {
  associatedtype RowView: ListRowView
  /// 選択の同一性（行の番号がずれても同じ選択を指す値）。
  associatedtype Selection: Hashable
  /// 行の組（行の数・区間の表・行の中身・選択の引き当ての元）。
  associatedtype Rows

  /// 今の行の組。
  var rows: Rows { get }
  /// 行の数。組が写しでない（その場で変わる）源のために、列は行を問う上限にも読み直した後のこの値を使う。
  func rowCount(in rows: Rows) -> Int
  /// 行の高さ——同じ高さの行が続く区間の表（先頭から順に `0..<rowCount` を隙間なく覆う。区間の前の余白は行の外）。列は
  /// 読み直すたびに写し、位置と行の引き当てを区間の数に比例する手間で済ませる（行の数に依らない）。
  func segments(in rows: Rows) -> [RowListSegment]
  /// 枠を 1 つ作る。列は見えている行の数＋1 本まで作って使い回す。
  func makeRowView() -> RowView
  /// 枠 `view` に行 `row` の中身を写す。列は並べるたび（送るたびを含む）に見えている全行について呼ぶので、中身が
  /// 前と同じなら描き直さない。
  /// `emoji` は chrome の絵文字の字体（ユーザー由来の名前に充てる）。
  func show(_ row: Int, of rows: Rows, in view: RowView, emoji: NSFont?)
  /// 選択 `selection` の行の番号（その組に無ければ nil）。
  func row(of selection: Selection, in rows: Rows) -> Int?
  /// 最初の行を描く前に 1 度だけ要る準備（字体の読み込み・初回の字組み・色の解決）。列が窓に載った次の周回で呼ぶ。
  func prepareRows(for appearance: NSAppearance)

  /// 列へ焦点を入れる要求があるか（列が窓に載ったとき・`update` で求められたときに見る）。
  var wantsFocus: Bool { get }
  /// 列が焦点の要求を当てた。
  func focusRequestDidApply()
  /// 列の焦点が入った・抜けた。
  func focusDidChange(_ focused: Bool)

  /// キーの操作。
  func perform(_ key: RowListKey, in rows: Rows)
  /// 列に焦点がある間に押していたキーを離した。
  func keyDidRelease()
  /// 行 `row` のシングルクリック。
  func click(_ row: Int, in rows: Rows)
  /// 行 `row` のダブルクリック。
  func doubleClick(_ row: Int, in rows: Rows)
  /// 行 `row` の中の部品 `control`（行の view が `control(at:)` で答えた番号）を押した。行のクリックにはならない。錨を
  /// 返せば、その行を押した行の高さに留め、押し続けの守りを張る（→ `RowListAnchor`）。
  func press(_ row: Int, control: Int, in rows: Rows) -> RowListAnchor<Selection>?
  /// VoiceOver がリストの行 `row` を選んだ。
  func select(_ row: Int, in rows: Rows)
}

extension RowListSource {
  func press(_ row: Int, control: Int, in rows: Rows) -> RowListAnchor<Selection>? { nil }
}

/// 行の中の部品を押した後、ポインタの下に留める行——押した行が組に在る間はその行、抜けたら後継の行（無ければ nil）。列は
/// 押した行の上端の窓の中の高さを覚え、組を読み直すたび・列の枠が窓の中で動くたびに、留める行の上端をその高さへ送る
/// （同じ位置で続けて押すと、次の行が次々に処理される）。送るのは原点が 0 に着くまでで、列の上に空きは作らない（届かなければ
/// 留めない）。下は一時の空きを足して留める。留める行が組に無ければ、今の原点を保つ。ポインタが列を出る・ホイールやキーで
/// 動かす・選択を見せるために送ると外す。
///
/// 錨を受け取った列は、押し続けの守り（→ `RowListPressGuard`）も張る——ポインタが押した部品の枠の中に居る間、その枠の中の
/// 押下は、留めている行の同じ部品に当たるときだけ通す。留めきれずにポインタの下へ来た見出し・別の行・列の外のものは働かない。
struct RowListAnchor<ID: Hashable> {
  let pressed: ID
  let successor: ID?
}

/// 同じ高さの行が続く区間。`leading` は区間の前の余白（行ではないので、押しても乗っても何も起きない）。
struct RowListSegment: Equatable {
  let start: Int
  let count: Int
  let height: CGFloat
  let leading: CGFloat

  init(start: Int, count: Int, height: CGFloat, leading: CGFloat = 0) {
    self.start = start
    self.count = count
    self.height = height
    self.leading = leading
  }
}

/// 列が源へ渡すキーの操作。
struct RowListKey: Equatable {
  enum Action {
    /// ↑↓（⇧つきも同じ）。
    case up, down
    case left, right
    case enter, escape
  }

  let action: Action
  /// 押し続けて自動で繰り返された押下（`NSEvent.isARepeat`）。
  let isRepeat: Bool
}

/// 行の列のスクロールの器。持ち主（pane）が持ち続け、載せる SwiftUI が隠れている間も捨てない——出し直すたびに行の
/// view を作り直さない。読む値（行の版・選択・焦点の要求・絵文字の字体）は `update` で受ける。OS のスクロールバーは
/// 持たず、サイドバーの一覧のつまみ（`RowListScrollbar`）を子として重ねる。ポインタの位置は列へ渡し、列がその下の行へ写す
/// （行の hover と行の中の部品）。
final class RowList<Source: RowListSource>: NSScrollView {
  let list: RowListView<Source>
  let scrollbar = RowListScrollbar()
  private var hoverArea: NSTrackingArea?
  private var rowsVersion: Int?
  /// 最後に写した選択。選択が変わったときだけ、その行を見せる（行の番号がずれただけ・列が出ただけでは送らない）。
  private var selection: Source.Selection?
  /// 大きさが決まる前に変わった選択。大きさの無い列で送ると、後で大きさが付いても送った位置が残るので、大きさが付いた
  /// 最初の `tile` で見せる。
  private var pendingReveal: Source.Selection?

  /// `rowHeight` は行 1 つ分の高さ（末尾の空き・ページ送りの重ね）。行そのものの高さは源の区間の表が決める。
  init(source: Source, rowHeight: CGFloat) {
    list = RowListView(source: source, rowHeight: rowHeight)
    super.init(frame: .zero)
    documentView = list
    drawsBackground = false
    borderType = .noBorder
    hasVerticalScroller = false
    hasHorizontalScroller = false
    automaticallyAdjustsContentInsets = false
    addSubview(scrollbar)
    scrollbar.onScroll = { [weak self] position in
      self?.list.releaseAnchor()
      self?.list.scroll(NSPoint(x: 0, y: position))
    }
    let hoverArea = NSTrackingArea(
      rect: .zero,
      options: [
        .mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect,
        .enabledDuringMouseDrag,
      ],
      owner: self)
    addTrackingArea(hoverArea)
    self.hoverArea = hoverArea
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  /// 行の版が変わった（か絵文字の字体が変わった）ときだけ行を読み直し、選択の行を写す。選択が変わったときだけ、
  /// その行を見えるところまで最小限だけ送る。
  func update(rowsVersion: Int, selection: Source.Selection?, emoji: NSFont?, wantsFocus: Bool) {
    if rowsVersion != self.rowsVersion || emoji !== list.emoji {
      self.rowsVersion = rowsVersion
      list.emoji = emoji
      list.reloadRows()
    }
    list.selectedRow = selection.flatMap(list.row(of:))
    if selection != self.selection {
      self.selection = selection
      pendingReveal = nil
      if let selection, let row = list.selectedRow {
        if contentSize.height > 0 {
          list.scrollRowToVisible(row)
        } else {
          pendingReveal = selection
        }
      }
    }
    if wantsFocus {
      // 焦点を移すと載せている SwiftUI の焦点も変わるので、この更新の外で当てる。
      DispatchQueue.main.async { [weak self] in self?.list.applyFocusRequest() }
    }
  }

  override func tile() {
    super.tile()
    list.fitWidth(to: contentSize.width)
    list.holdAnchor()
    list.layoutRows()
    scrollbar.reflect(metrics)
    guard contentSize.height > 0, let pending = pendingReveal else { return }
    pendingReveal = nil
    if let row = list.row(of: pending) { list.scrollRowToVisible(row) }
  }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    list.layoutRows()
    list.updatePointer()
    scrollbar.reflect(metrics)
  }

  private var metrics: SidebarScrollbar.Metrics {
    SidebarScrollbar.Metrics(
      position: contentView.bounds.minY, total: list.frame.height, visible: contentSize.height)
  }

  override func scrollWheel(with event: NSEvent) {
    list.releaseAnchor()
    super.scrollWheel(with: event)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    list.releaseAnchor()
    // 隠れる間にポインタが出ても出た通知は来ないので、載せ直すたびに外に居るところから始める。ポインタの真下に
    // 載ったときは入った通知も来ないので、動いたところで内外を決め直す（→ mouseMoved）。
    scrollbar.hover(false)
    list.pointerDidLeave()
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    // 焦点のある列へは外で動いても届くので、位置で内外を決める。
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    scrollbar.hover(inside)
    if inside {
      list.updatePointer()
    } else {
      list.releaseAnchor()
      list.pointerDidLeave()
    }
  }

  override func mouseEntered(with event: NSEvent) {
    guard event.trackingArea === hoverArea else { return super.mouseEntered(with: event) }
    scrollbar.hover(true)
    list.updatePointer()
  }

  override func mouseExited(with event: NSEvent) {
    guard event.trackingArea === hoverArea else { return super.mouseExited(with: event) }
    scrollbar.hover(false)
    list.releaseAnchor()
    list.pointerDidLeave()
  }
}
