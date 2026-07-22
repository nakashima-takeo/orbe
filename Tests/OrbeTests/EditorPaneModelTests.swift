import XCTest

@testable import Orbe

/// EditorPaneActions の no-op スパイ。focusTerminal だけフラグを立て edge-close のフォーカス返しを機械検証する。
private final class ActionsSpy: EditorPaneActions {
  var focusTerminalCalled = false
  func focusTerminal() { focusTerminalCalled = true }
  func stageFile(_ change: FileChange) {}
  func unstageFile(_ change: FileChange) {}
  func stageFiles(_ changes: [FileChange]) {}
  func unstageFiles(_ changes: [FileChange]) {}
  func discardFiles(_ changes: [FileChange]) {}
  func stageHunk(path: String, diff: FileDiff, hunkIndex: Int, untracked: Bool) {}
  func unstageHunk(path: String, diff: FileDiff, hunkIndex: Int) {}
  func commit(message: String) {}
  func loadMoreHistory() {}
  func selectHistory(_ selection: HistorySelection) {}
  func copyToPasteboard(_ text: String) {}
  func browserGoBack() {}
  func browserGoForward() {}
  func browserReload() {}
  func openBrowserExternally() {}
  func browserActivated() {}
}

/// EditorPaneModel の派生純粋ロジック（相対日時・StageBox 3状態・hunk 統合順・履歴レール）のテスト。
final class EditorPaneModelTests: XCTestCase {

  // MARK: - 相対日時

  func testRelativeDateBuckets() {
    func s(daysAgo: Int) -> String {
      let now = Date(timeIntervalSince1970: 1_000_000_000)
      return RelativeDate.string(
        from: now.addingTimeInterval(-Double(daysAgo) * 86400), now: now,
        LocalizationStore(language: .ja))
    }
    XCTAssertEqual(s(daysAgo: 0), "たった今")
    XCTAssertEqual(s(daysAgo: 1), "昨日")
    XCTAssertEqual(s(daysAgo: 29), "29日前")
    XCTAssertEqual(s(daysAgo: 45), "1ヶ月前")
    // 360〜364 日の帯で「0年前」を出さない回帰ガード。
    XCTAssertEqual(s(daysAgo: 361), "12ヶ月前")
    XCTAssertEqual(s(daysAgo: 364), "12ヶ月前")
    XCTAssertEqual(s(daysAgo: 365), "1年前")
    XCTAssertEqual(s(daysAgo: 800), "2年前")
  }

  // MARK: - StageBox 3状態

  func testStageState() {
    let model = EditorPaneModel()
    let staged = FileChange(path: "a", oldPath: nil, staged: .modified, unstaged: nil)
    let partial = FileChange(path: "b", oldPath: nil, staged: .modified, unstaged: .modified)
    let none = FileChange(path: "c", oldPath: nil, staged: nil, unstaged: .modified)
    let conflict = FileChange(path: "d", oldPath: nil, staged: .unmerged, unstaged: .unmerged)
    XCTAssertEqual(model.stageState(of: staged), .staged)
    XCTAssertEqual(model.stageState(of: partial), .partial)
    XCTAssertEqual(model.stageState(of: none), .none)
    // conflict は staged 情報があっても .none（stage 対象外）。
    XCTAssertEqual(model.stageState(of: conflict), .none)
  }

  // MARK: - フォルダ 3状態（conflict 除外）

  func testGroupStageState() {
    let model = EditorPaneModel()
    let staged = FileChange(path: "d/a", oldPath: nil, staged: .modified, unstaged: nil)
    let staged2 = FileChange(path: "d/b", oldPath: nil, staged: .modified, unstaged: nil)
    let none = FileChange(path: "d/c", oldPath: nil, staged: nil, unstaged: .modified)
    let conflict = FileChange(path: "d/e", oldPath: nil, staged: .unmerged, unstaged: .unmerged)
    func group(_ files: [FileChange]) -> PaneChangeGroup {
      PaneChangeGroup(id: "d/", dir: "d/", open: true, files: files, stat: (0, 0))
    }
    XCTAssertEqual(model.groupStageState(group([staged, staged2])), .staged, "全 staged")
    XCTAssertEqual(model.groupStageState(group([staged, none])), .partial, "一部 staged")
    // conflict は除外してから判定＝残り全 staged なら .staged。
    XCTAssertEqual(
      model.groupStageState(group([conflict, staged])), .staged, "conflict 除外で全 staged")
    XCTAssertEqual(model.groupStageState(group([conflict])), .none, "conflict のみ＝対象なし")
  }

  // MARK: - レールツール押下＝本体トグル

  func testSelectToolToggle() {
    let model = EditorPaneModel()
    // 閉→押下でそのツールを開く。
    model.selectTool(.git)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .git)
    // 開いていて別ツール押下は開いたまま切替。
    model.selectTool(.tree)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .tree)
    // 開いていて同ツール再押下で閉じる（ツールは維持）。
    model.selectTool(.tree)
    XCTAssertFalse(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .tree)
  }

  // Cmd+Shift+↑/↓: 開時は隣ツールへ移動（開いたまま）、端でさらに進むとラップせず本体を閉じる、閉時は端から開く。
  func testSelectAdjacentTool() {
    let model = EditorPaneModel()
    // 閉状態から↓: 直前ツールに関係なく先頭 tree を開く。
    model.selectAdjacentTool(1)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .tree)
    // 開いていれば隣へ: tree→git→browser。開いたまま。
    model.selectAdjacentTool(1)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .git)
    model.selectAdjacentTool(1)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .browser)
    // 下端 browser でさらに↓: ラップせず本体を閉じる（tool は維持）。
    model.selectAdjacentTool(1)
    XCTAssertFalse(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .browser)
    // 閉じてから↑: 直前 tool が末尾 browser でもトグル閉じは起きず末尾 browser を開く。
    model.selectAdjacentTool(-1)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .browser)
    // 開いていれば隣へ: browser→git→tree。開いたまま。
    model.selectAdjacentTool(-1)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .git)
    model.selectAdjacentTool(-1)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .tree)
    // 上端 tree でさらに↑: ラップせず本体を閉じる（tool は維持）。
    model.selectAdjacentTool(-1)
    XCTAssertFalse(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .tree)
    // 閉じてから↓: 直前 tool が tree でも先頭 tree を開く。
    model.selectAdjacentTool(1)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .tree)
  }

  // edge-close はフォーカスをターミナルへ返す（Cmd+/ 閉と同一副作用・条件5）。
  // 中間の隣接移動（selectTool 経由）では focusTerminal を呼ばない。
  func testSelectAdjacentToolEdgeCloseReturnsFocus() {
    // spy は model.actions（weak）を支えるためテスト側で強参照を保持する。
    let spy = ActionsSpy()
    let model = EditorPaneModel()
    model.actions = spy

    // 開・browser（下端）で↓ → 閉じてフォーカス返し。
    model.selectTool(.browser)
    spy.focusTerminalCalled = false
    model.selectAdjacentTool(1)
    XCTAssertFalse(model.ui.paneOpen)
    XCTAssertTrue(spy.focusTerminalCalled, "下端 browser でさらに↓の edge-close は focusTerminal を呼ぶ")

    // 開・tree（上端）で↑ → 閉じてフォーカス返し。
    model.selectTool(.tree)
    spy.focusTerminalCalled = false
    model.selectAdjacentTool(-1)
    XCTAssertFalse(model.ui.paneOpen)
    XCTAssertTrue(spy.focusTerminalCalled, "上端 tree でさらに↑の edge-close は focusTerminal を呼ぶ")

    // 中間の隣接移動（tree→git）は focusTerminal を呼ばない。
    model.selectTool(.tree)
    spy.focusTerminalCalled = false
    model.selectAdjacentTool(1)
    XCTAssertTrue(model.ui.paneOpen)
    XCTAssertEqual(model.ui.tool, .git)
    XCTAssertFalse(spy.focusTerminalCalled, "中間の隣接移動は focusTerminal を呼ばない")
  }

  // MARK: - hunk 統合順（新行番号順・同値は staged 優先）

  func testMergedHunksOrderStagedFirst() {
    let model = EditorPaneModel()
    let path = "x.swift"
    func diff(_ newStart: Int) -> FileDiff {
      FileDiff(
        oldPath: path, newPath: path, isBinary: false, oldMode: "100644", newMode: "100644",
        similarity: nil,
        hunks: [
          Hunk(
            oldStart: newStart, oldCount: 1, newStart: newStart, newCount: 1, sectionHeading: "",
            lines: [DiffLine(kind: .added, text: "+", newLine: newStart)])
        ])
    }
    model.files = [FileChange(path: path, oldPath: nil, staged: .modified, unstaged: .modified)]
    model.stagedDiffs = [path: diff(10)]
    model.unstagedDiffs = [path: diff(10)]  // staged と同じ新行番号
    let merged = model.mergedHunks(for: path)
    XCTAssertEqual(merged.count, 2)
    // 同一 newStart では staged が先。
    XCTAssertTrue(merged[0].staged)
    XCTAssertFalse(merged[1].staged)
  }

  // MARK: - 履歴レール（レーン・ドット・未コミットノード）

  func testHistoryRowsLanesAndDots() {
    let model = EditorPaneModel()
    // C（HEAD, 親 B）← B（親 A, マージ: 親2つ）← A（root）。D は off-chain。
    let head = Commit(
      oid: "c", shortOid: "c", author: "me", date: Date(), parents: ["b"], refs: ["HEAD -> main"],
      subject: "head")
    let merge = Commit(
      oid: "b", shortOid: "b", author: "me", date: Date(), parents: ["a", "d"], refs: [],
      subject: "merge")
    let root = Commit(
      oid: "a", shortOid: "a", author: "me", date: Date(), parents: [], refs: [], subject: "root")
    let side = Commit(
      oid: "d", shortOid: "d", author: "me", date: Date(), parents: ["a"], refs: [], subject: "side"
    )
    model.commits = [head, merge, root, side]
    model.unpushedOids = ["c"]
    let rows = model.historyRows()
    // files が空なので未コミットノードは無い。
    XCTAssertEqual(rows.map(\.id), ["c", "b", "a", "d"])
    // first-parent 連鎖 c→b→a は lane 0、off-chain の d は lane 1。
    XCTAssertEqual(rows.map(\.lane), [0, 0, 0, 1])
    if case .head = rows[0].dot {} else { XCTFail("HEAD 行のドットが .head でない") }
    if case .merge = rows[1].dot {} else { XCTFail("親2つの行のドットが .merge でない") }
    // HEAD の ref バッジ。
    XCTAssertEqual(rows[0].badges.map(\.label), ["HEAD"])
  }

  func testHistoryRowsUncommittedNodeWhenChanges() {
    let model = EditorPaneModel()
    model.files = [FileChange(path: "a", oldPath: nil, staged: nil, unstaged: .modified)]
    model.commits = [
      Commit(
        oid: "a", shortOid: "a", author: "me", date: Date(), parents: [], refs: [], subject: "root")
    ]
    let rows = model.historyRows()
    XCTAssertEqual(rows.first?.id, "uncommitted")
  }
}
