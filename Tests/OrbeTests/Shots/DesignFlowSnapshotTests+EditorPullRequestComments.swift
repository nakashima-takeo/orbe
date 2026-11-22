import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR のコメントの flow（fixture は `PrFixtures` と `PrFixtureReview`——本物の git の場と、PR #131 とスレッドを答える
/// 差し替えの出どころ）: PR の diff のスレッド（既定のスレッド・古い側の Markdown 入り・解決済みの畳んだ姿）→
/// コメント追加の印のホバー → 新しいコメントの欄 → 書き込みの最中 → 失敗 → 返信の後 → スレッドを畳む → 左の列を閉じて並列 →
/// 左の列を開き（インラインに戻る）、パネルの下端で全体へのコメントと「承認」を選ぶ → 送信の最中 → 送信の失敗 → 送信の後（保留中が 0）→ 書きかけの欄の行を書き換える
/// push の後（欄が書きかけを残して送れない姿）。
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
        ("review_draft", steps.draftReview),
        ("review_submitting", steps.submitReview),
        ("review_failed", steps.failReview),
        ("review_sent", steps.sendReview),
        ("line_gone", steps.rewriteDraftLine),
      ])
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

  /// 文脈の行（新しい側の行 8）にポインタを乗せ、行の右端の印の上へ動かす。
  func hoverMark() {
    guard let surface else { return XCTFail("前提: 面がある") }
    let y =
      surface.config.topInset + CGFloat(surface.rows.y(ofLine: 7) - surface.scrollPosition.y)
      + surface.config.lineHeight / 2
    surface.hover(
      at: CGPoint(x: surface.surfaceLayout.text.maxX - Theme.Layout.editorPrMarkInset - 9, y: y))
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

  /// 通る出どころでもう一度押す（保留中の返信が付き、欄が空になる）。
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

  /// 左の列を開き（インラインに戻る）、パネルの下端で全体へのコメントと「承認」を選ぶ。
  func draftReview() {
    scene.pane.sidebar.setOpen(true)
    let pane = scene.pane
    pumpMain(until: { pane.diff.map { pane.diffSurfaces($0).count == 1 } ?? false }, "インラインになる")
    settle()
    scene.panel.state?.reviewDraft.body = "コメントの分岐を確かめました。"
    scene.panel.chooseReviewEvent(.approve)
  }

  func submitReview() {
    scene.review.writes = .hold
    scene.panel.submitReview()
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
    scene.panel.submitReview()
    let panel = scene.panel
    pumpMain(until: { panel.state?.reviewDraft.body.isEmpty == true }, "送信が通る")
  }
}
