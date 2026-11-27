import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR のコメントの flow（fixture は `PrFixtures` と `PrFixtureReview`——本物の git の場と、PR #131 とスレッドを答える
/// 差し替えの出どころ）。3 つに分けて撮る。
/// - `editor_pr_comments`（dark）: PR の diff のスレッド（既定のスレッド・古い側の Markdown 入り・解決済みの畳んだ姿）→
///   行の頭のコメントの印のホバー → 新しいコメントの欄 → 書き込みの最中 → 失敗 → 返信の後 → スレッドを畳む → 左の列を閉じて並列。
/// - `editor_pr_review`（面を付けた窓の中で dark と light。窓から外れるとポップアップは閉じる）: 左の列を開き（インラインに
///   戻る）、レビューのポップアップを開いて全体へのコメントを書く → 「承認」を選ぶ → 「変更を依頼」を選ぶ → 未送信のコメントの
///   行を押す（ポップアップが閉じ、畳んだスレッドが開いてその行が見える）→ 開き直して「承認」で送信の最中 → 送信の失敗（下端の
///   赤い帯）→ 送信が通る（ポップアップが閉じ、未送信が 0）。
/// - `editor_pr_comments_after`（dark）: 書きかけの欄の行を書き換える push の後（欄が書きかけを残して送れない姿）。
///
/// 自分の PR のポップアップ（種類が無い）と、diff の両端を求められない PR の送れない理由は `testEditorPrReview`。
extension DesignFlowSnapshotTests {
  func testEditorPrComments() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try PrFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp(size: Self.size)
    pumpMain(until: { scene.isReady }, "PR の中身と帯が揃う")
    let steps = CommentSteps(scene: scene)
    try flow(
      "editor_pr_comments", size: Self.size, render: { scene.view },
      until: { scene.isReady && scene.isDiffReady },
      steps: [
        ("threads", steps.open),
        ("mark_hover", steps.hoverMark),
        ("new_comment", steps.newComment),
        ("writing", steps.write),
        ("failed", steps.fail),
        ("replied", steps.reply),
        ("collapsed", steps.collapse),
        ("side", steps.side),
      ])
    // flow は面を、dark に固定した撮影用の器へ載せ替えて撮るので、窓の外観で撮り分ける前に、面を素の窓へ戻す。
    scene.warmUp(size: Self.size)
    try renderInPlace(
      scene.pane, name: "editor_pr_review", dir: previewDir("flows"), appearances: [true, false],
      steps: [
        ("open", steps.openReview),
        ("approve", { steps.choose(.approve) }),
        ("changes", { steps.choose(.requestChanges) }),
        ("reveal", steps.revealPending),
        ("submitting", steps.submitReview),
        ("failed", steps.failReview),
        ("sent", steps.sendReview),
      ])
    try flow(
      "editor_pr_comments_after", size: Self.size, render: { scene.view },
      until: { scene.isReady && scene.isDiffReady },
      steps: [
        ("line_gone", steps.rewriteDraftLine)
      ])
  }

  /// レビューのポップアップの、人の PR の flow に出ない姿: 自分の PR（種類が無く、返信をまとめて送るだけ）と、diff の両端を
  /// 求められない PR（下端の帯に送れない理由）。
  func testEditorPrReview() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let own = try PrFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { own.cleanup() }
    own.review.viewerIsAuthor = true
    own.warmUp(size: Self.size)
    pumpMain(until: { own.isReady }, "PR の中身と帯が揃う")
    try renderInPlace(
      own.pane, name: "editor_pr_review_own", dir: previewDir("flows"), appearances: [true, false],
      steps: [("open", { Self.openReview(own, draft: "指摘いただいた点に対応しました。") })])
    let blocked = try PrFixtures.scene(
      .notFetched, queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { blocked.cleanup() }
    blocked.warmUp(size: Self.size)
    pumpMain(until: { blocked.isReady }, "PR の中身が揃う")
    try renderInPlace(
      blocked.pane, name: "editor_pr_review_blocked", dir: previewDir("flows"),
      appearances: [true, false], steps: [("no_diff", { Self.openReview(blocked, draft: "") })])
  }

  /// PR の失敗の札（StateHooks.swift の diff を出し、左の列を閉じた姿）: 確認済みを反映できない → GitHub から読めていない
  /// （中身とレビューのやりとりが同時に失敗しても 1 枚）→ 読めるようになった後、送信中に閉じたポップアップの送信の失敗 →
  /// × で全部閉じる。
  func testEditorPrFailureCards() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try PrFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp(size: Self.size)
    pumpMain(until: { scene.isReady }, "PR の中身と帯が揃う")
    let pane = scene.pane
    let panel = scene.panel
    let state = try XCTUnwrap(panel.state)
    try renderInPlace(
      pane, name: "editor_pr_cards", dir: previewDir("flows"), appearances: [true, false],
      steps: [
        (
          "viewed",
          {
            scene.openDiff()
            pumpMain(until: { scene.isDiffReady }, "StateHooks.swift の diff が揃う")
            pane.sidebar.setOpen(false)
            scene.faults.viewed = .rateLimited
            panel.toggleViewed(PrFixtureReview.path)
            pumpMain(until: { state.viewedFailure != nil }, "確認済みの書き込みが失敗する")
          }
        ),
        (
          "reading",
          {
            scene.faults.content = .unreachable
            scene.review.readFailure = .unreachable
            panel.refresh()
            pumpMain(
              until: { state.contentFailure != nil && state.reviewFailure != nil }, "読みが失敗する")
          }
        ),
        (
          "submission",
          {
            scene.faults.content = nil
            scene.review.readFailure = nil
            panel.refresh()
            pumpMain(
              until: { state.contentFailure == nil && state.reviewFailure == nil }, "読めるようになる")
            Self.openReview(scene, draft: "見ました。")
            scene.review.writes = .hold
            pane.reviewPopup.submit()
            pane.reviewPopup.toggle()
            scene.review.writes = .fail(.unreachable)
            scene.review.release()
            pumpMain(until: { state.submissionFailure != nil }, "閉じた後に送信が失敗する")
          }
        ),
        (
          "dismissed",
          {
            let cards = PrFailureCards.cards(
              of: panel.pullRequest, reviewIsOpen: pane.reviewPopup.isOpen,
              LocalizationStore(language: .ja))
            for card in cards { card.dismiss() }
          }
        ),
      ])
  }

  /// 全体へのコメントを `draft` にして、レビューのポップアップを開く（開けるまで待つ）。
  @MainActor
  private static func openReview(_ scene: PrFixtures.Scene, draft: String) {
    let review = scene.pane.reviewPopup
    pumpMain(until: { review.canOpen }, "レビューのやりとりが届く")
    scene.panel.state?.reviewDraft.body = draft
    review.toggle()
    pumpMain(until: { review.isOpen }, "ポップアップが開く")
  }

  private static let size = NSSize(width: 1100, height: 760)
}

/// PR のコメントの flow の各ステップ。
@MainActor
private struct CommentSteps {
  let scene: PrFixtures.Scene

  private var diff: EditorDiff? { scene.pane.diff }
  private var surface: MetalTextSurface? { diff?.newSurface as? MetalTextSurface }

  private func settle() {
    let scene = scene
    pumpMain(until: { scene.isDiffReady }, "PR の diff が揃う")
    diff?.old?.waitUntilCaughtUp()
    diff?.newRevision?.waitUntilCaughtUp()
    for surface in scene.pane.diff.map(scene.pane.diffSurfaces) ?? [] {
      (surface as? MetalTextSurface)?.flush()
    }
  }

  private func zone(_ id: String) -> PrCommentZone? {
    diff?.comments?.zone(thread: id)
  }

  func open() {
    scene.openDiff()
    settle()
    surface?.scroll(toFirstLine: 6)
    settle()
  }

  /// 文脈の行（新しい側の行 8）の頭の列にポインタを乗せる。
  func hoverMark() {
    guard let surface else { return XCTFail("前提: 面がある") }
    let y =
      surface.config.topInset + CGFloat(surface.rows.y(ofLine: 7) - surface.scrollPosition.y)
      + surface.config.lineHeight / 2
    surface.hover(at: CGPoint(x: Theme.Layout.editorPrMarkColumn / 2, y: y))
    settle()
  }

  /// 行 8 に新しいコメントの欄を開き、打つ。
  func newComment() {
    surface?.hover(at: nil)
    diff?.comments?.openDraft(.new, line: 7)
    settle()
    guard let draft = diff?.comments?.draft(.new, line: 7) else { return XCTFail("前提: 欄が開く") }
    surface?.replaceText(of: draft.field, with: "queue の label は定数に寄せたい")
    settle()
  }

  /// 書き込みの答えを返さない出どころで「レビューに追加」を押す（欄とボタンが押せない姿）。
  func write() {
    scene.review.writes = .hold
    guard let draft = diff?.comments?.draft(.new, line: 7) else { return XCTFail("前提: 欄") }
    draft.zone(.pressed(PrCommentControl.add))
    settle()
  }

  /// 書き込みを通し、既定のスレッドへの返信を失敗させる（本文が残り、失敗の文が出る）。
  func fail() {
    scene.review.writes = .succeed
    scene.review.release()
    settle()
    surface?.scroll(toFirstLine: 11)
    scene.review.writes = .fail(.unreachable)
    guard let thread = zone("T_coalesce") else { return XCTFail("前提: 既定のスレッド") }
    thread.surface?.replaceText(of: thread.field, with: "了解。それなら OK")
    thread.zone(.pressed(PrCommentControl.add))
    settle()
  }

  /// 通る出どころでもう一度押す（未送信の返信が付き、欄が空になる）。
  func reply() {
    scene.review.writes = .succeed
    zone("T_coalesce")?.zone(.pressed(PrCommentControl.add))
    settle()
  }

  func collapse() {
    zone("T_coalesce")?.zone(.pressed(PrCommentControl.collapse))
    settle()
  }

  /// 左の列を閉じる（本体が並列の境の値より広くなる）。
  func side() {
    zone("T_coalesce")?.zone(.pressed(PrCommentControl.collapse))
    scene.pane.sidebar.setOpen(false)
    let pane = scene.pane
    pumpMain(until: { pane.diff.map { pane.diffSurfaces($0).count == 2 } ?? false }, "並列になる")
    settle()
  }

  /// 左の列を開き（インラインに戻る）、全体へのコメントを書いて、レビューのポップアップを開く。
  func openReview() {
    scene.pane.sidebar.setOpen(true)
    let pane = scene.pane
    pumpMain(until: { pane.diff.map { pane.diffSurfaces($0).count == 1 } ?? false }, "インラインになる")
    settle()
    scene.panel.state?.reviewDraft.body = "コメントの分岐を確かめました。"
    pane.reviewPopup.toggle()
    pumpMain(until: { pane.reviewPopup.isOpen }, "ポップアップが開く")
  }

  func choose(_ event: GitHubReviewEvent) {
    scene.panel.state?.chooseReviewEvent(event)
  }

  /// 未送信のコメントの行（既定のスレッドの行 12。畳んである）を押す。
  func revealPending() {
    guard
      let comment = scene.panel.state?.pendingComments.first(where: { $0.thread == "T_coalesce" })
    else { return XCTFail("前提: 既定のスレッドの未送信のコメント") }
    scene.pane.reviewPopup.onOpenURL = { XCTFail("置ける行ではブラウザを開かない: \($0)") }
    scene.pane.reviewPopup.press(comment)
    settle()
  }

  /// 開き直して「承認」を選び、書き込みの答えを返さない出どころで送る。
  func submitReview() {
    let review = scene.pane.reviewPopup
    review.toggle()
    pumpMain(until: { review.isOpen }, "ポップアップが開く")
    choose(.approve)
    scene.review.writes = .hold
    review.submit()
  }

  func failReview() {
    scene.review.writes = .fail(.timedOut)
    scene.review.release()
    let panel = scene.panel
    pumpMain(until: { panel.state?.submissionFailure != nil }, "失敗が届く")
  }

  /// 行 7 に新しいコメントの欄を開いて打ち、行 7 を書き換える push を起こす。
  func rewriteDraftLine() {
    surface?.scroll(toFirstLine: 2)
    diff?.comments?.openDraft(.new, line: 6)
    settle()
    guard let draft = diff?.comments?.draft(.new, line: 6) else { return XCTFail("前提: 欄が開く") }
    surface?.replaceText(of: draft.field, with: "label は bundle id から作りたい")
    let rewritten = EditorDiffFixtures.edited.replacingOccurrences(
      of: "\"orbe.hooks\"", with: "\"orbe.agent.hooks\"")
    XCTAssertNoThrow(try scene.push(rewritten, subject: "StateHooks: queue の label を改める"))
    let panel = scene.panel
    pumpMain(
      until: { draft.notice == .lineGone && panel.pullRequest.drift == .inSync },
      "push の後、欄の行が無くなり、帯が手元の HEAD を PR の先頭と見る")
    settle()
  }

  func sendReview() {
    scene.review.writes = .succeed
    let review = scene.pane.reviewPopup
    review.submit()
    pumpMain(until: { !review.isOpen }, "送信が通り、ポップアップが閉じる")
  }
}
