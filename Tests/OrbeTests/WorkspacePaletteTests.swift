import XCTest

@testable import Orbe

/// workspace コマンドパレット（WorkspacePaletteModel・ドリルイン式）のロジック検証。
/// libghostty 非依存（@Observable モデルのみ・surface を生成しない）。
/// キー意図（move/activate/drillIn/goBack）と絞り込み（queryChanged）の意味メソッドを駆動し、
/// 公開面（setItems / 意味メソッド）とコールバックで振る舞いを固定する（描画は AppShell の .overlay）。
@MainActor
final class WorkspacePaletteTests: XCTestCase {

  // MARK: - ヘルパ

  private func palette() -> WorkspacePaletteModel {
    WorkspacePaletteModel(localization: LocalizationStore(language: .ja))
  }

  private func items(_ names: [(String, Bool)]) -> [WorkspacePaletteModel.Item] {
    names.enumerated().map {
      WorkspacePaletteModel.Item(
        index: $0.offset, name: $0.element.0, isActive: $0.element.1, dormant: false,
        agentRollup: [], dir: "/tmp/\($0.element.0)")
    }
  }

  /// 入力欄が first responder の間の方向キー/確定/取消（一覧・改名モード）。
  /// 入力欄の onKeyPress/onSubmit→意味メソッドの写像と同じ筋でモデルを駆動する。
  private func send(_ p: WorkspacePaletteModel, _ selector: Selector) {
    if selector == enter {
      p.render.onActivate()
    } else if selector == esc {
      p.render.onEscape()
    } else if selector == down {
      p.render.onDown()
    } else if selector == up {
      p.render.onUp()
    } else if selector == right {
      _ = p.render.onRight()
    }
  }
  private var enter: Selector { #selector(NSResponder.insertNewline(_:)) }
  private var esc: Selector { #selector(NSResponder.cancelOperation(_:)) }
  private var down: Selector { #selector(NSResponder.moveDown(_:)) }
  private var up: Selector { #selector(NSResponder.moveUp(_:)) }
  private var right: Selector { #selector(NSResponder.moveRight(_:)) }

  /// 詳細メニュー（入力欄なし＝カードがキーを捕捉）の素のキー入力。keyCode→意味メソッドの写像で駆動する。
  private func key(_ p: WorkspacePaletteModel, _ keyCode: UInt16) {
    switch keyCode {
    case kDown: p.render.onDown()
    case kUp: p.render.onUp()
    case kReturn: p.render.onActivate()
    case kLeft: p.render.onLeft()
    case kEsc: p.render.onEscape()
    default: break
    }
  }
  private let kDown: UInt16 = 125, kUp: UInt16 = 126, kReturn: UInt16 = 36, kLeft: UInt16 = 123,
    kEsc: UInt16 = 53

  /// クエリ入力（絞り込み駆動）。入力欄バインドの onChange と同じ筋で model を更新する。
  private func type(_ p: WorkspacePaletteModel, _ text: String) {
    p.render.query = text
    p.render.onQueryChange()
  }

  // MARK: - 一覧: Enter で切替・絞り込み・新規作成

  func testEnterFiresSwitchForSelectedWorkspace() {
    let p = palette()
    var switched: Int?
    p.onSwitch = { switched = $0 }
    p.setItems(items([("default", true), ("api", false), ("web", false)]))
    send(p, enter)
    XCTAssertEqual(switched, 0, "空クエリ時の Enter は先頭 workspace の switch")
  }

  func testMoveDownThenEnterSwitchesToSecond() {
    let p = palette()
    var switched: Int?
    p.onSwitch = { switched = $0 }
    p.setItems(items([("default", true), ("api", false), ("web", false)]))
    send(p, down)
    send(p, enter)
    XCTAssertEqual(switched, 1, "moveDown 後の Enter は 2 番目(index 1)の switch")
  }

  func testMoveUpFromTopWrapsToCreateFlowRow() {
    let p = palette()
    var switched: Int?
    var createFlow = false
    p.onSwitch = { switched = $0 }
    p.onCreateFlow = { createFlow = true }
    p.setItems(items([("a", true), ("b", false)]))
    send(p, up)  // 先頭で上 → 末尾（＝常設の createFlow 行）へラップ
    send(p, enter)
    XCTAssertTrue(createFlow, "末尾の常設 createFlow 行へラップし Enter で作成フォームへ")
    XCTAssertNil(switched)
  }

  func testMoveDownFromCreateFlowWrapsToFirstWorkspace() {
    let p = palette()
    var switched: Int?
    p.onSwitch = { switched = $0 }
    p.setItems(items([("a", true), ("b", false)]))
    send(p, up)  // 末尾の createFlow 行へ
    send(p, down)  // さらに下 → 先頭 workspace へラップ
    send(p, enter)
    XCTAssertEqual(switched, 0, "createFlow から下でラップし先頭 workspace を switch")
  }

  func testTypingFiltersToMatchingWorkspace() {
    let p = palette()
    var switched: Int?
    var created: String?
    p.onSwitch = { switched = $0 }
    p.onCreate = { created = $0 }
    p.setItems(items([("default", true), ("api", false), ("web", false)]))
    type(p, "ap")
    send(p, enter)
    XCTAssertEqual(switched, 1, "'ap' は 'api'(index 1) に絞り込まれ Enter で switch(1)")
    XCTAssertNil(created, "既存一致時は create を発火しない")
  }

  func testTypingFilterIsCaseInsensitive() {
    let p = palette()
    var switched: Int?
    p.onSwitch = { switched = $0 }
    p.setItems(items([("Default", true), ("API", false), ("Web", false)]))
    type(p, "WE")
    send(p, enter)
    XCTAssertEqual(switched, 2, "'WE' は大小無視で 'Web'(index 2) に一致")
  }

  func testTypingNonMatchingNameThenEnterCreates() {
    let p = palette()
    var created: String?
    var switched: Int?
    p.onCreate = { created = $0 }
    p.onSwitch = { switched = $0 }
    p.setItems(items([("default", true), ("api", false)]))
    type(p, "infra")  // 一致なし → create 行が出て選択される
    send(p, enter)
    XCTAssertEqual(created, "infra", "一致しない名前の Enter は create('infra')")
    XCTAssertNil(switched, "一致しない名前では switch しない")
  }

  func testExactMatchDoesNotOfferCreate() {
    let p = palette()
    var created: String?
    var switched: Int?
    p.onCreate = { created = $0 }
    p.onSwitch = { switched = $0 }
    p.setItems(items([("default", true), ("api", false)]))
    type(p, "api")
    send(p, enter)
    XCTAssertEqual(switched, 1, "完全一致名の Enter は switch")
    XCTAssertNil(created)
  }

  /// 休眠 workspace の行は減光フラグ付きで描画される（並びは渡された順のまま・並べ替えは host 側）。
  func testDormantWorkspaceRowIsDimmed() {
    let p = palette()
    p.setItems([
      WorkspacePaletteModel.Item(
        index: 0, name: "live", isActive: true, dormant: false, agentRollup: [], dir: "/"),
      WorkspacePaletteModel.Item(
        index: 1, name: "sleep", isActive: false, dormant: true, agentRollup: [], dir: "/"),
    ])
    XCTAssertEqual(p.render.rows.count, 3, "2 workspace ＋ 末尾の常設 createFlow 行")
    XCTAssertFalse(p.render.rows[0].dimmed, "起きている workspace の行は減光しない")
    XCTAssertTrue(p.render.rows[1].dimmed, "休眠 workspace の行は減光する")
    XCTAssertTrue(p.render.rows[2].createStyle, "末尾は作成導線（createFlow）の行")
  }

  // MARK: - 末尾常設の「＋ 新規ワークスペース」行

  func testCreateFlowRowAlwaysPresentAndFiresCallback() {
    let p = palette()
    var createFlow = false
    p.onCreateFlow = { createFlow = true }
    p.setItems(items([("default", true), ("api", false)]))
    let last = p.render.rows.last
    XCTAssertEqual(last?.createStyle, true, "末尾は作成導線の行スタイル")
    XCTAssertEqual(last?.trailingBadge, "⌘N", "右端に ⌘N バッジ")
    send(p, down)  // api
    send(p, down)  // createFlow
    send(p, enter)
    XCTAssertTrue(createFlow, "createFlow 行の Enter は onCreateFlow")
  }

  func testCreateFlowRowSurvivesFiltering() {
    let p = palette()
    p.setItems(items([("default", true), ("api", false)]))
    type(p, "zzz")  // 一致なし → [quick-create, createFlow]
    XCTAssertEqual(p.render.rows.count, 2, "quick-create 行＋末尾 createFlow")
    XCTAssertEqual(p.render.rows.last?.createStyle, true, "絞り込み中も createFlow は末尾に残る")
  }

  // MARK: - → で詳細メニューに潜る（改名 / 削除）

  func testRightArrowDrillsThenRenameCommits() {
    let p = palette()
    var renamed: (Int, String)?
    p.onRename = { renamed = ($0, $1) }
    p.setItems(items([("default", true), ("api", false)]))
    send(p, down)  // index 1("api") を選択
    send(p, right)  // → 詳細メニューへ潜る（rows: [改名, 削除], 選択=改名）
    key(p, kReturn)  // Enter で改名モード（field に現名 "api" がプリフィル）
    send(p, enter)  // 改名確定
    XCTAssertEqual(renamed?.0, 1, "改名対象は潜った先の workspace(index 1)")
    XCTAssertEqual(renamed?.1, "api", "改名は現名プリフィルで確定")
  }

  func testRightArrowThenDownThenEnterFiresClose() {
    let p = palette()
    var closed: Int?
    p.onClose = { closed = $0 }
    p.setItems(items([("default", true), ("api", false)]))
    send(p, down)  // index 1 を選択
    send(p, right)  // 詳細メニューへ（[改名, ディレクトリ, 削除]）
    key(p, kDown)  // ディレクトリへ
    key(p, kDown)  // 削除へ
    key(p, kReturn)  // Enter で削除
    XCTAssertEqual(closed, 1, "詳細メニューの削除は潜った先(index 1)の close")
  }

  /// 削除後、一覧のハイライト（render.selected）は最上段固定ではなくアクティブ workspace の行を指す。
  /// onClose は host の closeWorkspace→reloadPalette→setItems を模し、削除済みを除き新アクティブ反映済みの
  /// items を再投入する。アクティブが起源(row 0)でない配置で、選択が row 0 に固定されないことを固定する。
  func testCloseHighlightsActiveWorkspaceRowNotTop() {
    let p = palette()
    // 表示順 [origin(row0), B(row1・アクティブ), C(row2)]。C を削除する。
    p.setItems(items([("origin", false), ("B", true), ("C", false)]))
    var closed: Int?
    p.onClose = { idx in
      closed = idx
      // 削除後の再読込を模す：C を除き、アクティブ B(row1) 反映済みで再投入。
      p.setItems(self.items([("origin", false), ("B", true)]))
    }
    send(p, down)  // B(row1)
    send(p, down)  // C(row2)
    send(p, right)  // C の詳細メニューへ（[改名, ディレクトリ, 削除]）
    key(p, kDown)  // ディレクトリ
    key(p, kDown)  // 削除
    key(p, kReturn)  // 削除実行
    XCTAssertEqual(closed, 2, "潜った先(C・index 2)の close")
    XCTAssertEqual(p.render.selected, 1, "削除後ハイライトはアクティブ B の行(row1)。最上段固定ではない")
    XCTAssertEqual(p.render.rows[p.render.selected].label, "B", "選択行はアクティブ workspace")
  }

  /// 詳細メニューの「ディレクトリ」は現ディレクトリをプリフィルし、Enter で確定すると onSetDir を発火する。
  func testDrillThenSetDirCommitsWithPrefill() {
    let p = palette()
    var setDir: (Int, String)?
    p.onSetDir = { setDir = ($0, $1) }
    p.setItems(items([("default", true), ("api", false)]))  // dir は "/tmp/<名前>"
    send(p, down)  // index 1("api") を選択
    send(p, right)  // 詳細メニューへ（[改名, ディレクトリ, 削除]・選択=改名）
    key(p, kDown)  // ディレクトリへ
    key(p, kReturn)  // ディレクトリ編集モード（field に現 dir "/tmp/api" プリフィル）
    send(p, enter)  // 現値のまま確定
    XCTAssertEqual(setDir?.0, 1, "対象は潜った先の workspace(index 1)")
    XCTAssertEqual(setDir?.1, "/tmp/api", "現ディレクトリをプリフィルして確定")
  }

  /// ディレクトリ編集で空にして確定しても onSetDir は発火しない（空は無視・現状維持）。
  func testSetDirEmptyDoesNotCommit() {
    let p = palette()
    var setDir: (Int, String)?
    p.onSetDir = { setDir = ($0, $1) }
    p.setItems(items([("default", true)]))
    send(p, right)  // 詳細メニュー（[改名, ディレクトリ]・単一なので削除なし）
    key(p, kDown)  // ディレクトリへ
    key(p, kReturn)  // 編集モード
    XCTAssertEqual(p.render.query, "/tmp/default", "setDir モードに入り現 dir がプリフィルされている")
    type(p, "   ")  // 空白のみへ
    send(p, enter)
    XCTAssertNil(setDir, "空ディレクトリの確定は無視（現状維持）")
  }

  func testSingleWorkspaceHasNoDeleteInSubmenu() {
    // workspace が1つのとき詳細メニューに「削除」を出さない（最後の1つは消せない）。改名・ディレクトリは出す。
    let p = palette()
    var closed: Int?
    var renamed: (Int, String)?
    p.onClose = { closed = $0 }
    p.onRename = { renamed = ($0, $1) }
    p.setItems(items([("only", true)]))
    send(p, right)  // 詳細メニューへ（rows: [改名, ディレクトリ]・削除なし）
    key(p, kReturn)  // 先頭の改名へ → 改名モード
    send(p, enter)  // 改名確定
    XCTAssertNil(closed, "単一 workspace の詳細メニューに削除は無い")
    XCTAssertEqual(renamed?.0, 0, "改名は選べる（削除のみ不在）")
  }

  func testRightArrowOnCreateRowDoesNotDrill() {
    // create 行で → を押しても潜らない（workspace 行でないため）。Enter は create のまま。
    let p = palette()
    var created: String?
    p.onCreate = { created = $0 }
    p.setItems(items([("default", true)]))
    type(p, "infra")  // rows: [create] のみ
    send(p, right)  // → は無視（潜らない）
    send(p, enter)  // 一覧のまま create
    XCTAssertEqual(created, "infra", "create 行では → で潜らず Enter で作成")
  }

  // MARK: - 戻る / 閉じる

  func testLeftArrowReturnsFromSubmenuToList() {
    let p = palette()
    var switched: Int?
    var dismissed = false
    p.onSwitch = { switched = $0 }
    p.onDismiss = { dismissed = true }
    p.setItems(items([("default", true), ("api", false)]))
    send(p, right)  // 詳細メニューへ（default の詳細）
    key(p, kLeft)  // ← で一覧へ戻る（閉じない）
    XCTAssertFalse(dismissed, "← は詳細→一覧で、パレットは閉じない")
    send(p, enter)  // 一覧に戻っているので先頭の switch
    XCTAssertEqual(switched, 0, "一覧へ戻り Enter で switch(0)")
  }

  func testEscFromSubmenuReturnsToListNotDismiss() {
    let p = palette()
    var dismissed = false
    p.onDismiss = { dismissed = true }
    p.setItems(items([("default", true), ("api", false)]))
    send(p, right)  // 詳細メニューへ
    key(p, kEsc)  // Esc は詳細→一覧（閉じない）
    XCTAssertFalse(dismissed, "詳細メニューの Esc は一覧へ戻るだけ")
  }

  func testEscFromListDismisses() {
    let p = palette()
    var dismissed = false
    p.onDismiss = { dismissed = true }
    p.setItems(items([("default", true)]))
    send(p, esc)  // 一覧の Esc は閉じる
    XCTAssertTrue(dismissed, "一覧の Esc は onDismiss")
  }

  func testEscDuringRenameReturnsToSubmenuNotDismiss() {
    let p = palette()
    var dismissed = false
    var renamed: (Int, String)?
    p.onDismiss = { dismissed = true }
    p.onRename = { renamed = ($0, $1) }
    p.setItems(items([("default", true), ("api", false)]))
    send(p, down)  // api
    send(p, right)  // 詳細メニュー
    key(p, kReturn)  // 改名モードへ
    send(p, esc)  // Esc は改名→詳細（閉じず・確定せず）
    XCTAssertFalse(dismissed, "改名中の Esc はパレットを閉じない")
    XCTAssertNil(renamed, "Esc 取消では改名を確定しない")
  }
}

// MARK: - 削除後ハイライト（アクティブ WS 自身の削除）

extension WorkspacePaletteTests {

  /// アクティブ workspace 自身を削除すると、host は MRU の別 workspace を新アクティブに切り替える
  /// （closeWorkspace → .activeChanged）。この経路でハイライトが「削除前とは別の行」に居る新アクティブへ
  /// 追従することを固定する（削除対象の行を指し続けたり最上段に固定したりしない）。
  func testCloseActiveWorkspaceHighlightsNewActiveRow() {
    let p = palette()
    // 表示順 [origin(row0), B(row1・アクティブ), C(row2)]。アクティブ B 自身を削除する。
    p.setItems(items([("origin", false), ("B", true), ("C", false)]))
    var closed: Int?
    p.onClose = { idx in
      closed = idx
      // 削除後の再読込を模す：B を除き、新アクティブ origin(row0) 反映済みで再投入。
      p.setItems(self.items([("origin", true), ("C", false)]))
    }
    send(p, down)  // B(row1)
    send(p, right)  // B の詳細メニューへ（[改名, ディレクトリ, 削除]）
    key(p, kDown)  // ディレクトリ
    key(p, kDown)  // 削除
    key(p, kReturn)  // 削除実行
    XCTAssertEqual(closed, 1, "潜った先(アクティブ B・index 1)の close")
    XCTAssertEqual(
      p.render.selected, 0, "削除後ハイライトは新アクティブ origin の行(row0)。削除対象 B の行(row1)ではない")
    XCTAssertEqual(p.render.rows[p.render.selected].label, "origin", "選択行は新アクティブ workspace")
  }

  /// 開いた直後、選択カーソルはアクティブ workspace 行に載る（提示元が selectActiveRow を呼ぶ）。
  /// ハイライトは選択カーソルの 1 つだけなので、開いた瞬間の見た目がアクティブ行 1 つになる。
  func testSelectActiveRowPutsCursorOnActiveWorkspace() {
    let p = palette()
    p.setItems(items([("origin", false), ("B", true), ("C", false)]))
    p.selectActiveRow()
    XCTAssertEqual(p.render.selected, 1, "選択カーソルはアクティブ B の行(row1)")
    XCTAssertEqual(p.render.rows[p.render.selected].label, "B", "選択行はアクティブ workspace")
  }
}
