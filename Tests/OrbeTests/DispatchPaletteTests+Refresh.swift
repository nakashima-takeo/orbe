import XCTest

@testable import Orbe

/// 最新化モード（遅れた Local branch の 2 択）の遷移契約と、相ごとに意味の変わるキーの畳み方。
/// 「遅れている」の判定は provider（`DispatchWorktreeBaseTests`）が持ち、ここは入った後だけを見る。
@MainActor
extension DispatchPaletteTests {

  /// designSample の遅れた `main` 行（`origin/main` より 12 遅れ）。
  private func staleMain(_ p: DispatchPaletteModel) throws -> (DispatchItem, DispatchBranchSync) {
    let item = try XCTUnwrap(p.items.first { $0.name == "main" })
    return (item, try XCTUnwrap(item.sync))
  }

  /// 同期ピルは着地後の値だけ。ff できる遅れだけが選択画面の条件を満たす。
  func testSyncIsCarriedOnLocalBranchRowsOnlyAfterTheFetchLands() throws {
    let landed = makeModel()
    let (_, main) = try staleMain(landed)
    XCTAssertEqual(main.ahead, 0)
    XCTAssertEqual(main.behind, 12)
    XCTAssertTrue(main.isFastForwardable)
    let diverged = try XCTUnwrap(landed.items.first { $0.name == "perf/render-batching" }?.sync)
    XCTAssertFalse(diverged.isFastForwardable, "分岐（↑↓）は即作成")

    var input = DispatchSectionBuilder.Input.designSample
    input.remoteFetchLanded = false
    let pending = makeModel(input)
    XCTAssertNil(pending.items.first { $0.name == "main" }?.sync, "着地前は無印")
  }

  /// 入ると mode が変わり、カーソルは既定の「最新化して作成」。esc で一覧へ戻り、選択は入った行のまま。
  func testEnterAndExitKeepTheListCursor() throws {
    let p = makeModel()
    let (item, sync) = try staleMain(p)
    p.selected = try XCTUnwrap(p.items.firstIndex { $0.name == "main" })
    p.enterRefresh(item: item, sync: sync)
    XCTAssertEqual(p.mode, .refresh)
    XCTAssertEqual(p.refresh?.choice, .refreshed)
    XCTAssertEqual(p.refresh?.phase, .choosing)

    p.refresh?.move(1)
    XCTAssertEqual(p.refresh?.choice, .asIs)
    p.refresh?.move(1)
    XCTAssertEqual(p.refresh?.choice, .refreshed, "2 行のトグル")

    p.exitRefresh()
    XCTAssertEqual(p.mode, .list)
    XCTAssertNil(p.refresh)
    XCTAssertEqual(p.selectedItem?.name, "main", "カーソルは入った行のまま")
  }

  /// ⏎ はカーソルの行を実行する。「最新化して作成」は最新化中へ、「そのまま作成」は作成中へ。
  func testConfirmDispatchesTheCursorChoice() throws {
    let p = makeModel()
    let (item, sync) = try staleMain(p)
    var settled: [(DispatchStaleChoice, DispatchBranchSync)] = []
    p.onSettleStale = { settled.append(($0, $1)) }

    p.enterRefresh(item: item, sync: sync)
    p.confirmRefresh()
    XCTAssertEqual(settled.map(\.0), [.refreshed])
    XCTAssertEqual(settled.first?.1, sync)
    XCTAssertEqual(p.refresh?.phase, .updating)
    XCTAssertTrue(p.isBusy, "最新化中は入力を受け付けない")

    p.enterRefresh(item: item, sync: sync)
    p.refresh?.move(1)
    p.confirmRefresh()
    XCTAssertEqual(settled.map(\.0), [.refreshed, .asIs])
    XCTAssertEqual(p.refresh?.phase, .creating)
    XCTAssertTrue(p.isBusy)
  }

  /// busy（最新化中・作成中）では ⏎・↑↓・esc・r のどれも効かない——fetch は中断できないので、
  /// 中断できる顔をしない。
  func testBusyIgnoresEveryKey() throws {
    let p = makeModel()
    let (item, sync) = try staleMain(p)
    var count = 0
    p.onSettleStale = { _, _ in count += 1 }
    p.enterRefresh(item: item, sync: sync)
    p.startRefresh()
    XCTAssertEqual(count, 1)

    p.refresh?.move(1)
    XCTAssertEqual(p.refresh?.choice, .refreshed)
    p.confirmRefresh()
    p.retryRefresh()
    XCTAssertEqual(count, 1, "二重起動しない")
    p.exitRefresh()
    XCTAssertEqual(p.mode, .refresh, "esc でも抜けない")
  }

  /// 失敗すると同じ画面に戻り、カーソルは「そのまま作成」へ落ちる。`r` と行 0 の ⏎ で再試行できる。
  func testFailureFallsBackToAsIsAndCanRetry() throws {
    let p = makeModel()
    let (item, sync) = try staleMain(p)
    var choices: [DispatchStaleChoice] = []
    p.onSettleStale = { choice, _ in choices.append(choice) }
    p.enterRefresh(item: item, sync: sync)
    p.startRefresh()
    p.refresh?.fail(.fetch(.timedOut))
    XCTAssertEqual(p.refresh?.phase, .failed(.fetch(.timedOut)))
    XCTAssertEqual(p.refresh?.choice, .asIs)
    XCTAssertFalse(p.isBusy)

    p.retryRefresh()
    XCTAssertEqual(choices, [.refreshed, .refreshed])
    XCTAssertEqual(p.refresh?.choice, .refreshed, "再試行で行 0 へ戻る")
    XCTAssertEqual(p.refresh?.phase, .updating)

    p.refresh?.fail(.fastForward(nil))
    p.startRefresh()
    XCTAssertEqual(choices.count, 3, "行 0 のタップも再試行")

    p.enterRefresh(item: item, sync: sync)
    p.retryRefresh()
    XCTAssertEqual(choices.count, 3, "失敗していなければ r は効かない")
  }

  /// 最新化の後の作成が落ちたら、一覧へ戻って理由をフッタに出す（既存の失敗 UI）。
  /// 一覧の Enter の失敗も同じ 1 本を通る。
  func testFailedPreparationReturnsToTheListWithTheReason() throws {
    let p = makeModel()
    let (item, sync) = try staleMain(p)
    p.enterRefresh(item: item, sync: sync)
    p.startRefresh()
    p.refresh?.beginCreating()
    p.failPreparation("fatal: boom")
    XCTAssertEqual(p.mode, .list)
    XCTAssertNil(p.refresh)
    XCTAssertEqual(p.errorMessage, "fatal: boom")
    XCTAssertFalse(p.isBusy)

    p.isPreparing = true
    p.failPreparation("nope")
    XCTAssertFalse(p.isPreparing)
    XCTAssertEqual(p.errorMessage, "nope")
    XCTAssertEqual(p.mode, .list)
  }
}
