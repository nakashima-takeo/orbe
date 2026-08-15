import XCTest

@testable import Orbe

/// worktree の 3 群への振り分けと 3 軸の語彙（純粋関数）。**「要らないの推定」と「消して安全か」が
/// 別レイヤ**で、安全確認を 1 つでも落とした worktree が safe に入らないことを固定する。
final class DispatchWorktreeClassifierTests: OrbeTestCase {

  /// 作業ツリーが clean（安全確認を通る側）。
  let clean = GitWorktreeStatusCounts(modified: 0, untracked: 0)

  private func classify(_ facts: DispatchCleanFacts...) -> [CleanRow] {
    DispatchWorktreeClassifier.classify(facts)
  }

  func row(_ facts: DispatchCleanFacts) -> CleanRow {
    DispatchWorktreeClassifier.classify([facts])[0]
  }

  // MARK: - 群の振り分け

  /// Issue #84 の実測ケース: upstream は消えているが独自コミットが残る → **caution**（初期選択に入らない）。
  /// 軸B は損失を隠さない順に選ぶので `独自コミット 6 件` が先。軸A が黙っていて枠が余るので、
  /// 灰の `[gone]` は潰されず 2 枚目に出る。
  func testGoneWithOwnCommitsStaysCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/wt-path-template", branch: "ship/wt", upstream: "origin/ship/wt",
        track: "[gone]",
        closedPR: DispatchCleanPR(number: 120, isMerged: false, base: "main"), status: clean,
        containment: .unmerged(count: 6), operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(r.chips, [.ownCommits(6), .gone])
    XCTAssertEqual(r.lossNotes, [.ownCommits(6)], "黄ピルの行は展開サブラインに損失の内訳を書く")
  }

  /// PR が MERGED で安全確認を全部通れば safe。失うものが無いので軸A は何も名乗らず、
  /// **空いた枠は軸B の 2 枚目で埋まる**——安全の根拠を 1 つだけ出して黙らない。
  /// merged PR チップが立つ行では証明ピル（`merged → main`）はピル枠を争わずサブラインへ降り、
  /// 空いた枠は次の事実が埋める（同じ「merged」を 2 枚並べない）。
  func testMergedPRPassingEveryCheckIsSafe() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/dispatch-delete", branch: "feat/dispatch-delete", upstream: "origin/x",
        closedPR: DispatchCleanPR(number: 142, isMerged: true, base: "main"), status: clean,
        containment: .patchEquivalent(target: "main"), operation: .none))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedPR(142, base: "main"), .remoteSynced])
    XCTAssertEqual(
      r.overflowNotes, [.mergedInto("main")],
      "降りた語は台帳に残る（safe 行では描かれないが、同じ主張を PR チップが可視で引き受ける）")
    XCTAssertTrue(r.deletesBranchImplicitly)
  }

  /// 未コミット変更があれば推定が立っていても safe に入らない。件数は軸A の語彙で出る。
  func testDirtyFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/diff-panel", branch: "fix/diff-panel", upstream: "origin/fix/diff-panel",
        track: "[gone]",
        status: GitWorktreeStatusCounts(modified: 2, untracked: 3),
        containment: .patchEquivalent(target: "main"),
        operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(
      r.chips, [.uncommitted(2), .mergedInto("main")], "軸A + 軸B から 1 枚ずつ")
    XCTAssertEqual(
      r.lossNotes, [.uncommitted(2), .untracked(3)], "ピルから溢れた損失は内訳へ回る")
  }

  /// **status が clean でも rebase 途中なら safe に入らない**（コンフリクトの無い停止点で status は空になる）。
  func testInProgressOperationKeepsRowOutOfSafe() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/mid-rebase", branch: "feat/mid", upstream: "origin/feat/mid",
        track: "[gone]", status: clean,
        containment: .patchEquivalent(target: "main"), operation: .inProgress(.rebase)))
    XCTAssertEqual(r.group, .caution, "status が空でも停止中の操作は安全確認を落とす")
    XCTAssertEqual(r.chips, [.inProgress(.rebase), .mergedInto("main")])
  }

  /// 実際の操作名で出す（merge 中の行に `rebase 進行中` と書かない）。
  func testInProgressNamesTheActualOperation() {
    for operation in [GitWorktreeOperation.merge, .cherryPick, .bisect] {
      let r = row(
        DispatchCleanFacts(
          path: "/wt/x", branch: "feat/x", track: "[gone]", status: clean,
          containment: .patchEquivalent(target: "main"),
          operation: .inProgress(operation)))
      XCTAssertEqual(r.chips.first, .inProgress(operation))
    }
  }

  /// 停止中の操作を判定できなかった行も safe に入らない（分からないものを安全と名乗らない）。
  func testUnknownOperationFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", status: clean,
        containment: .patchEquivalent(target: "main"),
        operation: .unknown))
    XCTAssertEqual(r.group, .caution)
  }

  /// status を採れなかった行も safe に入らない（実体はあるのに status だけが nil、は分類レーンの
  /// 実測が落ちれば起きる）。**確認できていない作業ツリーを安全群へ入れない**。
  func testUnknownStatusFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", track: "[gone]", status: nil,
        containment: .patchEquivalent(target: "main"),
        operation: .none))
    XCTAssertEqual(r.group, .caution)
  }

  /// 実体が無い（prunable）なら「ディスク上に失うものが無い」ので、作業ツリー側の確認
  /// （status・停止中の操作）は自動的に満たす。
  func testPrunableIsSafeWithoutProbingTheWorkingTree() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/render-batching", branch: "perf/render-batching", isPrunable: true,
        upstream: "origin/perf/render-batching", track: "[gone]",
        containment: .patchEquivalent(target: "main")))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(
      r.chips, [.prunable, .mergedInto("main")], "軸A + 軸B のピル 1 枚ずつ")
    XCTAssertFalse(r.deletesBranchImplicitly, "消えるのは登録だけ。ブランチには触らない")
  }

  /// locked は `--force` 1 個では外れないので caution に置く（必ず失敗する初期チェックを作らない）。
  func testLockedFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/held", branch: "feat/held", lockReason: "USB", track: "[gone]", status: clean,
        containment: .patchEquivalent(target: "main"), operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertTrue(r.chips.contains(.locked), "軸C で唯一ピルになる語")
  }

  /// 取り込み済み判定ができなかった行は safe に入らない。
  func testUnknownMergeStateFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", track: "[gone]",
        status: clean, containment: nil, operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(
      r.chips, [.gone, .unverified],
      "件数を名乗れないので独自コミットの語は出さず、確かめられなかった事実を判定不能チップが名乗る")
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
          containment: .patchEquivalent(target: "main"),
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
        containment: .patchEquivalent(target: "main"), operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(r.chips, [.mergedInto("main"), .remoteSynced])
  }

  // MARK: - 軸B の語彙と優先順位

  /// upstream が無ければ `未 push · ローカルのみ`。open PR があればそちらが先に立つ。
  func testAxisBPrefersTheLoudestLoss() {
    let unpushed = row(
      DispatchCleanFacts(path: "/wt/x", branch: "feat/x", status: clean, containment: nil))
    XCTAssertEqual(unpushed.chips.first, .unpushed)

    let openPR = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", openPR: 139, status: clean, containment: nil))
    XCTAssertEqual(openPR.chips.first, .openPR(139), "レビュー中の PR は未 push より先に名乗る")

    let ownCommits = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", openPR: 139, status: clean,
        containment: .unmerged(count: 3)))
    XCTAssertEqual(ownCommits.chips.first, .ownCommits(3), "失うコミットが最優先")
  }

  /// `未 push · ローカルのみ` は「そのコミットがどこにも残らない」という主張なので、
  /// **比較先へ取り込み済みの行では言わない**——remote に無くても内容は残る。
  /// 取り込み判定ができなかった行では言い切れないので、損失として名乗る。
  func testUnpushedIsNotClaimedWhenTheContentIsAlreadyInDefault() {
    let merged = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x",
        closedPR: DispatchCleanPR(number: 142, isMerged: true, base: "main"),
        status: clean, containment: .patchEquivalent(target: "main"), operation: .none))
    XCTAssertEqual(merged.group, .safe)
    XCTAssertFalse(
      merged.vocabulary.contains(.unpushed), "失うものが無い行に完全喪失の警告を出さない")
    XCTAssertEqual(
      merged.chips, [.mergedPR(142, base: "main")],
      "merged PR チップが安全根拠として立ち、証明ピルはサブラインへ降りる")
    XCTAssertEqual(merged.overflowNotes, [.mergedInto("main")])

    let unknown = row(
      DispatchCleanFacts(path: "/wt/x", branch: "feat/x", status: clean, containment: nil))
    XCTAssertTrue(unknown.vocabulary.contains(.unpushed), "判定できていない行では名乗る")
  }

  /// `remote +N` も同じ主張なので、取り込み済みの行では言わない。
  func testRemoteAheadIsNotClaimedWhenTheContentIsAlreadyInDefault() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", track: "[ahead 3]",
        closedPR: DispatchCleanPR(number: 142, isMerged: true, base: "main"), status: clean,
        containment: .patchEquivalent(target: "main"),
        operation: .none))
    XCTAssertFalse(r.vocabulary.contains(.remoteAhead(3)))
  }

  /// `%(upstream:track)` から先行件数を読む（`[ahead N, behind M]` も拾う）。
  func testRemoteAheadReadsTheTrackField() {
    let ahead = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", track: "[ahead 3]",
        status: clean, containment: nil))
    XCTAssertEqual(ahead.chips.first, .remoteAhead(3))

    let diverged = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", track: "[ahead 1, behind 2]",
        status: clean, containment: nil))
    XCTAssertEqual(diverged.chips.first, .remoteAhead(1))
  }

  /// upstream があり track が空なら「ローカルを消しても origin に残る」。取り込み判定が
  /// できなかった事実は判定不能チップが名乗る（確認群にいる理由の可視化）。
  func testRemoteSyncedWhenTrackIsEmpty() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", upstream: "origin/feat/x", status: clean,
        containment: nil, operation: .none))
    XCTAssertEqual(
      r.chips, [.remoteSynced, .unverified])
  }

  /// detached はブランチの行き先そのものが無い（サブラインを開かない条件でもある）。
  func testDetachedRowHasNoBranchVocabulary() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", status: clean, containment: .patchEquivalent(target: "main"),
        operation: .none))
    XCTAssertTrue(r.chips.isEmpty)
    XCTAssertFalse(r.deletesBranchImplicitly)
  }

  /// ピルは軸A + 軸B の最大 2 枚。3 つ以上重なったら loss を優先し、残りは損失の内訳へ回る。
  func testPillsAreCappedAtTwoPreferringLoss() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", lockReason: "USB", upstream: "origin/feat/x",
        track: "[gone]",
        status: GitWorktreeStatusCounts(modified: 1, untracked: 0),
        containment: .unmerged(count: 4),
        operation: .none))
    XCTAssertEqual(r.chips.filter(\.isPill).count, 2)
    XCTAssertEqual(r.chips, [.uncommitted(1), .ownCommits(4)])
    XCTAssertEqual(
      r.lossNotes, [.uncommitted(1), .ownCommits(4)],
      "内訳は消える対象を名指す語だけ（`locked` は琥珀でも失うものではない）")
    XCTAssertEqual(
      r.overflowNotes, [.locked, .gone], "上限に載らなかった候補は溢れの受け皿へ回る")
  }

  /// **detached の確認行もサブラインを開ける。** rebase 停止中の worktree は必ず detached で、
  /// 衝突中は未コミットも untracked も在るので軸A が 3 語競合する——ブランチが無いことを理由に
  /// 閉じると、取り消せない削除の直前に失うものが画面から落ちる。
  func testDetachedCautionRowCanStillOpenItsDetail() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", status: GitWorktreeStatusCounts(modified: 2, untracked: 3),
        operation: .inProgress(.rebase)))
    XCTAssertEqual(r.group, .caution)
    XCTAssertNil(r.branch)
    XCTAssertEqual(
      r.chips,
      [.inProgress(.rebase), .unverified],
      "detached でも取り込み判定は oid で問うので、確かめられなかった事実が名乗る")
    XCTAssertEqual(
      r.lossNotes, [.inProgress(.rebase), .uncommitted(2), .untracked(3)],
      "ピルから溢れた untracked も内訳に出る")
    XCTAssertTrue(r.canExpandSubline, "ブランチが無くても書くことがあるなら開く")
  }

  /// 開くものが何も無い確認行は開かない（空のサブラインを作らない）。
  func testCautionRowWithNothingToSayDoesNotExpand() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", status: clean, containment: .patchEquivalent(target: "main"),
        operation: .none))
    XCTAssertEqual(r.group, .caution)
    XCTAssertTrue(r.vocabulary.isEmpty)
    XCTAssertFalse(r.canExpandSubline)
  }

  /// open PR の行は安全群に入れない。安全群はブランチ削除が無条件になる群だが、
  /// レビュー中のブランチの既定は「残す」——初期チェック済みで並べると確認の機会が無い。
  func testOpenPullRequestKeepsTheRowInCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", isPrunable: true, openPR: 139,
        containment: .patchEquivalent(target: "main")))
    XCTAssertEqual(r.group, .caution)
    XCTAssertFalse(r.deletesBranchImplicitly, "レビュー中のブランチを黙って消さない")
  }

  /// 上限に載らなかったピル候補は、**損失でなくても**サブラインへ回る。
  /// 受け皿を損失の内訳と兼ねると、`locked` はピルからも内訳からも落ちて画面から消える——
  /// その行が安全群に入れない理由そのものなので、読めなくなると確認群にいる理由が説明されない。
  func testCappedPillsSurviveAsOverflow() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/session-restore", branch: "feat/session-restore", lockReason: "USB",
        status: clean, containment: .patchEquivalent(target: "main"),
        operation: .inProgress(.rebase)))
    XCTAssertEqual(r.chips, [.inProgress(.rebase), .locked], "右クラスタは loss を優先した 2 枚")
    XCTAssertEqual(r.lossNotes, [.inProgress(.rebase)])
    XCTAssertEqual(r.overflowNotes, [.mergedInto("main")])
    XCTAssertFalse(
      r.lossNotes.contains(.locked), "locked は消えないので `〜も消えます` には入れない")
  }

  /// 溢れるのは軸C の `locked` とは限らない。loss でない軸B の語が押し出されたときも受け皿へ回る。
  func testOverflowCarriesTheDroppedBranchVocabulary() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", lockReason: "USB", upstream: "origin/feat/x",
        status: clean, containment: .patchEquivalent(target: "main"), operation: .inProgress(.merge)
      ))
    XCTAssertEqual(r.chips, [.inProgress(.merge), .locked], "loss の 2 枚が残る")
    XCTAssertEqual(r.overflowNotes, [.mergedInto("main"), .remoteSynced])
  }

  // MARK: - 並びと件数

  func testRowsAreOrderedByGroup() {
    let rows = classify(
      DispatchCleanFacts(path: "/repo", branch: "main", isMain: true),
      DispatchCleanFacts(
        path: "/wt/dirty", branch: "a", track: "[gone]",
        status: GitWorktreeStatusCounts(modified: 1, untracked: 0), operation: .none),
      DispatchCleanFacts(
        path: "/wt/safe", branch: "b", track: "[gone]", status: clean,
        containment: .patchEquivalent(target: "main"),
        operation: .none))
    XCTAssertEqual(rows.map(\.name), ["safe", "dirty", "repo"], "safe → caution → inUse の群順")
    XCTAssertEqual(DispatchWorktreeClassifier.candidateCount(rows), 1, "候補件数は safe 群から導く")
  }

  /// clean 画面の meta 列は**ブランチ名だけ**（パスは list モードが見せる）。
  func testMetaIsTheBranchName() {
    XCTAssertEqual(row(DispatchCleanFacts(path: "/wt/x", branch: "feat/x")).meta, "feat/x")
    XCTAssertEqual(row(DispatchCleanFacts(path: "/wt/x")).meta, "/wt/x", "detached はパスへ落とす")
  }

}
