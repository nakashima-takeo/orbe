import XCTest

@testable import Orbe

/// worktree の 3 群への振り分けと 3 軸の語彙（純粋関数）。**「要らないの推定」と「消して安全か」が
/// 別レイヤ**で、安全確認を 1 つでも落とした worktree が safe に入らないことを固定する。
final class DispatchWorktreeClassifierTests: OrbeTestCase {

  /// 作業ツリーが clean（安全確認を通る側）。
  private let clean = GitWorktreeStatusCounts(modified: 0, untracked: 0)

  private func classify(_ facts: DispatchCleanFacts...) -> [CleanRow] {
    DispatchWorktreeClassifier.classify(facts, defaultBranchLabel: "main")
  }

  private func row(_ facts: DispatchCleanFacts) -> CleanRow {
    DispatchWorktreeClassifier.classify([facts], defaultBranchLabel: "main")[0]
  }

  // MARK: - 群の振り分け

  /// Issue #84 の実測ケース: upstream は消えているが独自コミットが残る → **caution**（初期選択に入らない）。
  /// 軸B は損失を隠さない順に選ぶので、灰の `[gone]` ではなく `独自コミット 6 件` がピルに出る。
  func testGoneWithOwnCommitsStaysCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/wt-path-template", branch: "ship/wt", upstream: "origin/ship/wt",
        track: "[gone]",
        closedPR: DispatchCleanPR(number: 120, isMerged: false), status: clean,
        unmergedCommits: 6, operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(r.chips, [.ownCommits(6)])
    XCTAssertEqual(r.lossNotes, [.ownCommits(6)], "黄ピルの行は展開サブラインに損失の内訳を書く")
  }

  /// PR が MERGED で安全確認を全部通れば safe。失うものが無いので軸A は何も名乗らず、
  /// 右クラスタは軸B のピルと行内注記の 2 つになる。
  func testMergedPRPassingEveryCheckIsSafe() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/dispatch-delete", branch: "feat/dispatch-delete", upstream: "origin/x",
        closedPR: DispatchCleanPR(number: 142, isMerged: true), status: clean,
        unmergedCommits: 0, operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedPR(142), .branchAlsoDeleted])
    XCTAssertTrue(r.deletesBranchImplicitly)
  }

  /// 未コミット変更があれば推定が立っていても safe に入らない。件数は軸A の語彙で出る。
  func testDirtyFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/diff-panel", branch: "fix/diff-panel", upstream: "origin/fix/diff-panel",
        track: "[gone]",
        status: GitWorktreeStatusCounts(modified: 2, untracked: 3), unmergedCommits: 0,
        operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(
      r.chips, [.uncommitted(2), .mergedIntoDefault("main")], "軸A + 軸B から 1 枚ずつ")
    XCTAssertEqual(
      r.lossNotes, [.uncommitted(2), .untracked(3)], "ピルから溢れた損失は内訳へ回る")
  }

  /// **status が clean でも rebase 途中なら safe に入らない**（コンフリクトの無い停止点で status は空になる）。
  func testInProgressOperationKeepsRowOutOfSafe() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/mid-rebase", branch: "feat/mid", upstream: "origin/feat/mid",
        track: "[gone]", status: clean,
        unmergedCommits: 0, operation: .inProgress(.rebase)))
    XCTAssertEqual(r.group, .caution, "status が空でも停止中の操作は安全確認を落とす")
    XCTAssertEqual(r.chips, [.inProgress(.rebase), .mergedIntoDefault("main")])
  }

  /// 実際の操作名で出す（merge 中の行に `rebase 進行中` と書かない）。
  func testInProgressNamesTheActualOperation() {
    for operation in [GitWorktreeOperation.merge, .cherryPick, .bisect] {
      let r = row(
        DispatchCleanFacts(
          path: "/wt/x", branch: "feat/x", track: "[gone]", status: clean, unmergedCommits: 0,
          operation: .inProgress(operation)))
      XCTAssertEqual(r.chips.first, .inProgress(operation))
    }
  }

  /// 停止中の操作を判定できなかった行も safe に入らない（分からないものを安全と名乗らない）。
  func testUnknownOperationFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", status: clean, unmergedCommits: 0,
        operation: .unknown))
    XCTAssertEqual(r.group, .caution)
  }

  /// status を採れなかった行も safe に入らない（実体はあるのに status だけが nil、は分類レーンの
  /// 実測が落ちれば起きる）。**確認できていない作業ツリーを安全群へ入れない**。
  func testUnknownStatusFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", status: nil, unmergedCommits: 0,
        operation: .none))
    XCTAssertEqual(r.group, .caution)
  }

  /// 実体が無い（prunable）なら「ディスク上に失うものが無い」ので、作業ツリー側の確認
  /// （status・停止中の操作）は自動的に満たす。
  func testPrunableIsSafeWithoutProbingTheWorkingTree() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/render-batching", branch: "perf/render-batching", isPrunable: true,
        upstream: "origin/perf/render-batching", track: "[gone]", unmergedCommits: 0))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(
      r.chips, [.prunable, .mergedIntoDefault("main")], "軸A + 軸B のピル 1 枚ずつ")
    XCTAssertFalse(r.deletesBranchImplicitly, "消えるのは登録だけ。ブランチには触らない")
  }

  /// locked は `--force` 1 個では外れないので caution に置く（必ず失敗する初期チェックを作らない）。
  func testLockedFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/held", branch: "feat/held", lockReason: "USB", track: "[gone]", status: clean,
        unmergedCommits: 0, operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertTrue(r.chips.contains(.locked), "軸C で唯一ピルになる語")
  }

  /// 取り込み済み判定ができなかった行は safe に入らない。
  func testUnknownMergeStateFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", track: "[gone]",
        status: clean, unmergedCommits: nil, operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(r.chips, [.gone], "件数を名乗れないので独自コミットの語は出さない")
  }

  func testMainWorktreeIsInUse() {
    let r = row(DispatchCleanFacts(path: "/repo", branch: "main", isMain: true))
    XCTAssertEqual(r.group, .inUse)
    XCTAssertEqual(r.chips, [.mainWorktree])
  }

  /// `agentState` は 3 分岐に開く（working / waiting / それ以外）。
  func testOccupiedWorktreeNamesTheAgentState() {
    func chips(_ state: String?) -> [CleanChip] {
      row(
        DispatchCleanFacts(
          path: "/wt/agent-hooks", branch: "feature/agent-hooks", track: "[gone]",
          unmergedCommits: 0,
          occupancy: PaneOccupancy(cwd: "/wt/agent-hooks", agentState: state))
      ).chips
    }
    XCTAssertEqual(chips("working"), [.agentWorking])
    XCTAssertEqual(chips("waiting"), [.agentWaiting])
    XCTAssertEqual(chips("done"), [.paneOpen])
    XCTAssertEqual(chips(nil), [.paneOpen], "素のシェルでもタブが開いていれば使用中")
  }

  /// 推定が 1 つも立たなければ、安全確認を通っていても候補にはしない。
  func testNoHintStaysCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/plain", branch: "feat/plain", upstream: "origin/plain", status: clean,
        unmergedCommits: 0, operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(r.chips, [.mergedIntoDefault("main")])
  }

  // MARK: - 軸B の語彙と優先順位

  /// upstream が無ければ `未 push · ローカルのみ`。open PR があればそちらが先に立つ。
  func testAxisBPrefersTheLoudestLoss() {
    let unpushed = row(
      DispatchCleanFacts(path: "/wt/x", branch: "feat/x", status: clean, unmergedCommits: 0))
    XCTAssertEqual(unpushed.chips.first, .unpushed)

    let openPR = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", openPR: 139, status: clean, unmergedCommits: 0))
    XCTAssertEqual(openPR.chips.first, .openPR(139), "レビュー中の PR は未 push より先に名乗る")

    let ownCommits = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", openPR: 139, status: clean, unmergedCommits: 3))
    XCTAssertEqual(ownCommits.chips.first, .ownCommits(3), "失うコミットが最優先")
  }

  /// `%(upstream:track)` から先行件数を読む（`[ahead N, behind M]` も拾う）。
  func testRemoteAheadReadsTheTrackField() {
    let ahead = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", track: "[ahead 3]",
        status: clean, unmergedCommits: 0))
    XCTAssertEqual(ahead.chips.first, .remoteAhead(3))

    let diverged = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", track: "[ahead 1, behind 2]",
        status: clean, unmergedCommits: 0))
    XCTAssertEqual(diverged.chips.first, .remoteAhead(1))
  }

  /// upstream があり track が空なら「ローカルを消しても origin に残る」。
  func testRemoteSyncedWhenTrackIsEmpty() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", status: clean,
        unmergedCommits: nil, operation: .none))
    XCTAssertEqual(r.chips, [.remoteSynced])
  }

  /// detached はブランチの行き先そのものが無い（サブラインを開かない条件でもある）。
  func testDetachedRowHasNoBranchVocabulary() {
    let r = row(DispatchCleanFacts(path: "/wt/x", status: clean, unmergedCommits: 0))
    XCTAssertTrue(r.chips.isEmpty)
    XCTAssertFalse(r.deletesBranchImplicitly)
  }

  /// ピルは軸A + 軸B の最大 2 枚。3 つ以上重なったら loss を優先し、残りは損失の内訳へ回る。
  func testPillsAreCappedAtTwoPreferringLoss() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", lockReason: "USB", upstream: "origin/feat/x",
        track: "[gone]",
        status: GitWorktreeStatusCounts(modified: 1, untracked: 0), unmergedCommits: 4,
        operation: .none))
    XCTAssertEqual(r.chips.filter(\.isPill).count, 2)
    XCTAssertEqual(r.chips, [.uncommitted(1), .ownCommits(4)])
    XCTAssertEqual(
      r.lossNotes, [.uncommitted(1), .ownCommits(4)],
      "内訳は消える対象を名指す語だけ（`locked` は琥珀でも失うものではない）")
    XCTAssertEqual(r.overflowNotes, [.locked], "上限に載らなかった候補は溢れの受け皿へ回る")
  }

  /// 上限に載らなかったピル候補は、**損失でなくても**サブラインへ回る。
  /// 受け皿を損失の内訳と兼ねると、`locked` はピルからも内訳からも落ちて画面から消える——
  /// その行が安全群に入れない理由そのものなので、読めなくなると確認群にいる理由が説明されない。
  func testCappedPillsSurviveAsOverflow() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/session-restore", branch: "feat/session-restore", lockReason: "USB",
        status: clean, unmergedCommits: 0, operation: .inProgress(.rebase)))
    XCTAssertEqual(r.chips, [.inProgress(.rebase), .unpushed], "右クラスタは loss を優先した 2 枚")
    XCTAssertEqual(r.lossNotes, [.inProgress(.rebase)])
    XCTAssertEqual(r.overflowNotes, [.locked])
    XCTAssertFalse(
      r.lossNotes.contains(.locked), "locked は消えないので `〜も消えます` には入れない")
  }

  /// 溢れるのは軸C の `locked` とは限らない。loss でない軸B の語が押し出されたときも受け皿へ回る。
  func testOverflowCarriesTheDroppedBranchVocabulary() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", lockReason: "USB", upstream: "origin/feat/x",
        status: clean, unmergedCommits: 0, operation: .inProgress(.merge)))
    XCTAssertEqual(r.chips, [.inProgress(.merge), .locked], "loss の 2 枚が残る")
    XCTAssertEqual(r.overflowNotes, [.mergedIntoDefault("main")])
  }

  /// **ピル候補は 1 つも画面から消えない。** 3 軸が競合しうる組み合わせを総当たりし、
  /// 候補として立った語が右クラスタ・損失の内訳・溢れの受け皿のどれかに必ず出ることを主張する。
  func testNoPillCandidateEverDisappears() {
    for lockReason in [nil, "USB"] as [String?] {
      for operation in [GitWorktreeOperationState.none, .inProgress(.rebase)] {
        for upstream in [nil, "origin/feat/x"] as [String?] {
          for unmergedCommits in [0, 4] {
            let r = row(
              DispatchCleanFacts(
                path: "/wt/x", branch: "feat/x", lockReason: lockReason, upstream: upstream,
                status: clean, unmergedCommits: unmergedCommits, operation: operation))
            let visible = r.chips + r.lossNotes + r.overflowNotes
            let shape = "lock=\(lockReason != nil) op=\(operation) up=\(upstream != nil)"
            XCTAssertTrue(
              r.overflowNotes.allSatisfy { !r.chips.contains($0) },
              "溢れの受け皿は右クラスタと重ならない（\(shape)）")
            if lockReason != nil {
              XCTAssertTrue(visible.contains(.locked), "locked がどこにも出ない（\(shape)）")
            }
            if case .inProgress(let name) = operation {
              XCTAssertTrue(
                visible.contains(.inProgress(name)), "進行中の操作が消えた（\(shape)）")
            }
            if unmergedCommits > 0 {
              XCTAssertTrue(
                visible.contains(.ownCommits(unmergedCommits)), "独自コミットが消えた（\(shape)）")
            }
          }
        }
      }
    }
  }

  /// 損失の内訳はトーンではなく「何が失われるか」で決まる。**琥珀の語でも消えないものは書かない**——
  /// 破壊操作の直前に `PR #N open も消えます` という事実と違う一文を出さないため。
  func testLossNotesExcludeVocabularyThatIsNotLost() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", lockReason: "USB", openPR: 139,
        status: GitWorktreeStatusCounts(modified: 12, untracked: 3), unmergedCommits: 0,
        operation: .none))
    XCTAssertEqual(r.lossNotes, [.uncommitted(12), .untracked(3)])
    XCTAssertFalse(r.lossNotes.contains(.openPR(139)), "PR は worktree を消しても残る")
    XCTAssertFalse(r.lossNotes.contains(.locked), "locked は削除を止める状態であって損失ではない")
    XCTAssertFalse(r.lossNotes.contains(.unpushed), "失われるコミットは独自コミットの語が名指す")
  }

  // MARK: - 並びと件数

  func testRowsAreOrderedByGroup() {
    let rows = classify(
      DispatchCleanFacts(path: "/repo", branch: "main", isMain: true),
      DispatchCleanFacts(
        path: "/wt/dirty", branch: "a", track: "[gone]",
        status: GitWorktreeStatusCounts(modified: 1, untracked: 0), operation: .none),
      DispatchCleanFacts(
        path: "/wt/safe", branch: "b", track: "[gone]", status: clean, unmergedCommits: 0,
        operation: .none))
    XCTAssertEqual(rows.map(\.name), ["safe", "dirty", "repo"], "safe → caution → inUse の群順")
    XCTAssertEqual(DispatchWorktreeClassifier.candidateCount(rows), 1, "候補件数は safe 群から導く")
  }

  /// clean 画面の meta 列は**ブランチ名だけ**（パスは list モードが見せる）。
  func testMetaIsTheBranchName() {
    XCTAssertEqual(row(DispatchCleanFacts(path: "/wt/x", branch: "feat/x")).meta, "feat/x")
    XCTAssertEqual(row(DispatchCleanFacts(path: "/wt/x")).meta, "/wt/x", "detached はパスへ落とす")
  }

  // MARK: - ペイン占有の帰属

  /// 子ディレクトリにいるペインも占有。判定はパス構成要素単位で、文字列 prefix ではない。
  func testOccupancyMatchesChildDirectoryButNotSiblingPrefix() {
    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/a/foo"],
      panes: [PaneOccupancy(cwd: "/a/foo/src/deep", agentState: nil)])
    XCTAssertNotNil(map["/a/foo"], "子ディレクトリは占有")

    let sibling = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/a/foo"], panes: [PaneOccupancy(cwd: "/a/foobar", agentState: nil)])
    XCTAssertTrue(sibling.isEmpty, "接頭辞が一致するだけの兄弟は占有ではない")
  }

  /// 入れ子の worktree では最も長く一致した方に帰属する（親と子の両方を占有にしない）。
  func testOccupancyPrefersLongestMatch() {
    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/a/repo", "/a/repo/wt/child"],
      panes: [PaneOccupancy(cwd: "/a/repo/wt/child/src", agentState: nil)])
    XCTAssertNil(map["/a/repo"])
    XCTAssertNotNil(map["/a/repo/wt/child"])
  }

  /// symlink（macOS の `/tmp` → `/private/tmp`）を解決してから突き合わせる。
  /// OSC 7 が報告する pwd と `git worktree list` のパスは素では一致しないことがある。
  func testOccupancyResolvesSymlinks() throws {
    let name = "orbe-occupancy-\(UUID().uuidString)"
    let path = "/tmp/\(name)"
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: [path],
      panes: [PaneOccupancy(cwd: "/private/tmp/\(name)", agentState: nil)])
    XCTAssertNotNil(map[path])
  }

  /// 同じ worktree に複数ペインが居たら waiting > working > done で 1 つに畳む。
  func testOccupancyFoldsByAgentPriority() {
    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/wt/x"],
      panes: [
        PaneOccupancy(cwd: "/wt/x", agentState: "done"),
        PaneOccupancy(cwd: "/wt/x/sub", agentState: "waiting"),
        PaneOccupancy(cwd: "/wt/x", agentState: "working"),
      ])
    XCTAssertEqual(map["/wt/x"]?.agentState, "waiting")
  }
}
