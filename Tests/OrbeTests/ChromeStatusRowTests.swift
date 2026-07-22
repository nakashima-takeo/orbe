import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 常駐 chrome（ネイティブ SwiftUI `StatusRowView` ＋ `StatusRowModel`）の完了条件を検証する。
///
/// 条件1: macOS のウィンドウタイトルバーを表示しない。
/// 条件2: chrome に workspace 名・タブ・アクティブペインの cwd が同居し、タブ 1 枚でも見える。
/// 条件3: この chrome 以外に常駐 UI を増やさない（オーバーレイは呼んだ時だけ）。
///
/// 描画は SwiftUI なので、行レベルの状態は `WindowController.statusModel`（SSOT）で検証する。
/// タブの shrink-to-fit は純関数 `StatusTabLayout.widths` を単体検査する。
final class ChromeStatusRowTests: XCTestCase {

  private var tempStore: URL!
  override func setUp() {
    super.setUp()
    tempStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-test-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tempStore
    SettingsPersistence.fileURLOverride = tempStore.appendingPathExtension("settings")
    AppStatePersistence.fileURLOverride = tempStore.appendingPathExtension("appstate")
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay を出さない。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }
  override func tearDown() {
    WorkspacePersistence.fileURLOverride = nil
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempStore)
    super.tearDown()
  }

  // MARK: - 検査ヘルパ

  private func rootHost(_ wc: WindowController) throws -> NSView {
    try XCTUnwrap(wc.window.contentView, "SwiftUI ルートの contentView")
  }

  private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    var found: [T] = []
    if let v = view as? T { found.append(v) }
    for sub in view.subviews { found += findAll(type, in: sub) }
    return found
  }

  // MARK: - 条件1: タイトルバー非表示

  func testTitlebarIsNotShown() {
    let wc = WindowController()
    XCTAssertEqual(wc.window.titleVisibility, .hidden, "タイトル文字列は描画されない")
    XCTAssertTrue(wc.window.titlebarAppearsTransparent, "タイトルバー背景は透明")
    XCTAssertTrue(
      wc.window.styleMask.contains(.fullSizeContentView),
      "コンテンツがタイトルバー領域まで広がる（専用のタイトルバー帯が無い）")
    let frame = wc.window.frame
    let content = wc.window.contentRect(forFrameRect: frame)
    XCTAssertEqual(content, frame, "フレーム全体がコンテンツ領域＝タイトルバー帯ゼロ")
  }

  // MARK: - 条件2: workspace 名・タブ・cwd が同居し、タブ 1 枚でも常に見える

  /// 起動直後（workspace 1・タブ 1 枚）でも chrome が最上段に高さ付きで存在し、本文と重ならない。
  func testChromeRowIsVisibleEvenWithSingleTab() throws {
    let wc = WindowController()
    let host = try rootHost(wc)
    host.layoutSubtreeIfNeeded()

    // chrome はターミナル本文（SurfaceView）より上に位置し、重ならない。
    let pane = try XCTUnwrap(findAll(SurfaceView.self, in: host).first, "アクティブペイン")
    let paneInHost = pane.convert(pane.bounds, to: host)
    let chromeBottom = host.isFlipped ? Chrome.barHeight : host.bounds.height - Chrome.barHeight
    let paneTop = host.isFlipped ? paneInHost.minY : paneInHost.maxY
    XCTAssertEqual(paneTop, chromeBottom, accuracy: 1, "本文は chrome の真下から始まる＝chrome は常時占有")

    // タブ 1 枚でも 1 タブぶんのタイトルが chrome 状態に出る。
    wc.flushChrome()  // chrome は coalesce 済み——同期読み前に最終状態を確定させる
    XCTAssertEqual(wc.statusModel.titles.count, 1, "タブ 1 枚でもタブが 1 つ見える")
  }

  /// workspace 名・各タブのタイトル・cwd が同じ chrome（statusModel）に同居する。
  func testWorkspaceNameTabsAndCwdCohabitTheRow() throws {
    let wc = WindowController()
    let host = try rootHost(wc)

    wc.flushChrome()  // chrome は coalesce 済み——同期読み前に最終状態を確定させる
    XCTAssertEqual(wc.statusModel.workspace, "default", "workspace 名が chrome に出る")

    // アクティブペインが cwd を報告すると、chrome 行に実 cwd が 1 箇所だけ出る（OSC 7 経路）。
    let pane = try XCTUnwrap(findAll(SurfaceView.self, in: host).first, "アクティブペイン")
    pane.currentPwd = "/private/var/orbe-cwd-probe"
    pane.controller?.panePwdChanged()
    wc.flushChrome()
    XCTAssertEqual(
      wc.statusModel.cwd, "/private/var/orbe-cwd-probe", "cwd は chrome 行に 1 箇所だけ出る")

    // タブタイトルは ③ 派生で cwd の fish 圧縮名になる（root 外＝home 外なので絶対 compact）。
    // 行の実 cwd（フルパス）とは別表現＝同じ文字列の埋め込みではない。
    XCTAssertEqual(
      wc.statusModel.titles.first, "/p/v/orbe-cwd-probe",
      "タブタイトルは cwd の派生圧縮名: \(wc.statusModel.titles)")
    XCTAssertNotEqual(
      wc.statusModel.titles.first, wc.statusModel.cwd, "タブタイトルは行の実 cwd フルパスとは別表現")
  }

  /// workspace 切替で chrome の workspace 名も追従する。
  func testRowWorkspaceNameFollowsActiveWorkspace() throws {
    let wc = WindowController()
    wc.createWorkspace(name: "infra")
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.workspace, "infra", "切替後の workspace 名が chrome に出る")

    wc.switchWorkspace(to: 0)
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.workspace, "default", "戻すと default が chrome に出る")
  }

  /// タブを増やすと chrome のタブ数が増え、アクティブは 1 つ。
  func testTabsAppearInsideTheSameRow() throws {
    let wc = WindowController()
    wc.newTab()
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.titles.count, 2, "タブ 2 が chrome に出る")
    XCTAssertTrue(
      wc.statusModel.titles.indices.contains(wc.statusModel.active), "アクティブ index は範囲内")
  }

  // MARK: - 横断エージェント状態ロールアップ

  /// アクティブ workspace の全ペインの状態が rollup 件数に出る。件数 0 の種別は出ない。
  func testRollupShowsActivePaneStateCounts() throws {
    let wc = WindowController()
    let host = try rootHost(wc)
    let pane = try XCTUnwrap(findAll(SurfaceView.self, in: host).first, "アクティブペイン")

    wc.flushChrome()
    XCTAssertTrue(wc.statusModel.rollup.isEmpty, "状態 0 なら rollup は空")

    pane.agentState = "working"
    pane.controller?.paneAgentStateChanged()  // onAgentStateChange → refreshChrome 経路
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.rollup.map(\.state), ["working"], "working セグメントが出る")
    XCTAssertEqual(wc.statusModel.rollup.first?.count, 1, "working 1 件")
  }

  /// done → idle に遷移したペインは idle 件数として rollup に出る。
  func testRollupReflectsDoneToIdleTransition() throws {
    let wc = WindowController()
    let host = try rootHost(wc)
    let pane = try XCTUnwrap(findAll(SurfaceView.self, in: host).first, "アクティブペイン")

    pane.agentState = "done"
    pane.controller?.paneAgentStateChanged()
    pane.agentState = "idle"
    pane.controller?.paneAgentStateChanged()
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.rollup.map(\.state), ["idle"], "idle セグメントになる")
    XCTAssertEqual(wc.statusModel.rollup.first?.count, 1, "idle 1 件")
  }

  // MARK: - 条件3: chrome 以外に常駐 UI を増やさない

  /// 安静時（起動直後・タブ追加後）はターミナル本文が同居し、オーバーレイは存在しない。
  func testNoOtherPersistentChromeAtRest() throws {
    let wc = WindowController()
    let host = try rootHost(wc)

    XCTAssertFalse(findAll(SurfaceView.self, in: host).isEmpty, "ターミナル内容が同居する")
    XCTAssertEqual(wc.presentedOverlay, .none, "パレットは常駐しない")
    XCTAssertTrue(findAll(SearchBar.self, in: host).isEmpty, "検索バーは常駐しない")

    wc.newTab()
    wc.createWorkspace(name: "second")
    XCTAssertEqual(wc.presentedOverlay, .none, "操作後もパレットは常駐しない")
    XCTAssertTrue(findAll(SearchBar.self, in: host).isEmpty, "操作後も検索バーは常駐しない")
  }

  /// オーバーレイは呼んだ時だけ現れる。
  func testPaletteAppearsOnlyOnDemand() {
    let wc = WindowController()
    XCTAssertEqual(wc.presentedOverlay, .none, "呼ぶ前は無い")
    wc.showWorkspacePalette()
    XCTAssertEqual(wc.presentedOverlay, .workspacePalette, "呼ぶと出る")
  }

  // MARK: - タブ shrink-to-fit（純関数）

  private let gap = Chrome.tabGap
  private let plus = Chrome.tabHeight
  private let minW = Chrome.tabMinWidth
  private let maxW = Chrome.tabMaxWidth

  /// 少数タブ（広い）: 全タブが自然幅で、合計は available 以内（スクロール不要）。
  func testFewTabsUseNaturalWidthWithoutScroll() {
    let naturals: [CGFloat] = [120, 120]
    let widths = StatusTabLayout.widths(naturals: naturals, available: 800)
    XCTAssertEqual(widths, naturals, "収まる時は自然幅")
    let total = widths.reduce(0, +) + gap * CGFloat(widths.count) + plus
    XCTAssertLessThanOrEqual(total, 800, "合計は available 以内＝スクロール不要")
  }

  /// 長いタブ名: 空間が余っていても maxWidth で cap され、省略記号側（DSTab）へ切り詰めを回す。
  func testLongTitlesAreCappedAtMaxWidth() {
    let naturals: [CGFloat] = [320, 80]
    let widths = StatusTabLayout.widths(naturals: naturals, available: 800)
    XCTAssertEqual(widths, [maxW, 80], "自然幅が上限を超えるタブだけ cap される")
  }

  /// 溢れ（比例縮小）: 全タブが自然幅に比例して縮み、短いタブも縮む（CSS flex shrink と同じ）。
  /// 床に達したタブは凍結され、残りへ再配分されて合計はちょうど room に収まる。
  func testOverflowShrinksProportionallyAndRedistributes() {
    let naturals: [CGFloat] = [100, 50, 100, 50]
    let available: CGFloat = 260  // room = 260 - 2*4 - 22 = 230 < 300
    let widths = StatusTabLayout.widths(naturals: naturals, available: available)
    let room = available - gap * 4 - plus
    XCTAssertEqual(widths.reduce(0, +), room, accuracy: 0.5, "床に達しない限り合計は room に一致")
    XCTAssertLessThan(widths[1], 50, "短いタブも比例して縮む")
    XCTAssertGreaterThan(widths[0], widths[1], "縮小後も自然幅の大小関係を保つ")
  }

  /// 多数タブ（狭い）: 各タブは最小幅まで縮む（自然幅を超えない・下回らない）。
  func testManyTabsShrinkToMinWidth() {
    let naturals = Array(repeating: CGFloat(120), count: 8)
    let widths = StatusTabLayout.widths(naturals: naturals, available: 300)
    XCTAssertEqual(widths.count, 8)
    for w in widths {
      XCTAssertGreaterThanOrEqual(w, minW, "最小幅 \(minW) を下回らない")
      XCTAssertLessThan(w, 120, "溢れる時は縮む")
    }
  }

  /// 最小幅でも収まらないほど詰めると、合計が available を超え横スクロールが成立する。
  func testOverflowMakesContentScrollable() {
    let naturals = Array(repeating: CGFloat(120), count: 8)
    let widths = StatusTabLayout.widths(naturals: naturals, available: 300)
    let total = widths.reduce(0, +) + gap * CGFloat(widths.count) + plus
    XCTAssertGreaterThan(total, 300, "最小幅でも溢れたら合計 > available ＝横スクロールできる")
    for (i, w) in widths.enumerated() {
      XCTAssertGreaterThan(w, 0, "タブ \(i) は幅 > 0（潰れた不可達タブを作らない）")
    }
  }

  /// 幅を変えると shrink ⇄ 自然幅が再計算される（リサイズ追従）。
  func testWidthChangeRecomputesShrink() {
    let naturals = Array(repeating: CGFloat(120), count: 8)
    let narrow = StatusTabLayout.widths(naturals: naturals, available: 300)
    XCTAssertLessThan(narrow[0], 120, "狭い時は shrink される")

    let wide = StatusTabLayout.widths(naturals: naturals, available: 1200)
    XCTAssertEqual(wide, naturals, "広げると自然幅へ戻る")
  }
}
