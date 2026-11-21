import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// PR のパネルの flow（fixture は `PrFixtures`——本物の git の場と、PR #131 を答える差し替えの出どころ）:
/// 初期状態 → 確認済みを付ける → フォルダの配下をまとめて外す → リスト表示 → 説明とコミットを畳む → 変更
/// ファイルを開く（PR の diff。タブ行に「確認済みにする」）→ 確認済みにする → PR が無い（作成の入口）→ ブランチが未公開
/// → gh が認証されていない → PR の先頭が手元に無い（数えない違いの帯）→ 既定のブランチ → コミットの題とファイル名に絵文字。
extension DesignFlowSnapshotTests {
  func testEditorPr() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try PrFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "PR の中身と帯が揃う")
    var current = scene
    var others: [PrFixtures.Scene] = []
    defer { others.forEach { $0.cleanup() } }
    let switchTo = { (answer: PrFixtures.Answer) in
      guard
        let next = try? PrFixtures.scene(answer, queriesRoot: queriesRoot, in: TestScratch.caseDir)
      else { return XCTFail("fixture") }
      next.warmUp()
      pumpMain(until: { next.isReady }, "答えが出る")
      others.append(next)
      current = next
    }
    let panel = scene.panel
    try flow(
      "editor_pr", size: NSSize(width: 1100, height: 640), render: { current.view },
      until: { current.isReady && (current.pane.diff == nil || current.isDiffReady) },
      steps: [
        ("open", { panel.select(.file("src/agent/StateHooks.swift")) }),
        ("viewed", { panel.toggleViewed("README.md") }),
        (
          "folder_unviewed",
          {
            panel.toggleViewed(folder: [
              "src/agent/EmitBuffer.swift", "src/agent/HookRegistry.swift",
            ])
          }
        ),
        ("list", { scene.pane.sidebar.setPullRequestFilesAsTree(false) }),
        (
          "folded",
          {
            scene.pane.sidebar.setPullRequestFilesAsTree(true)
            panel.isDescriptionOpen = false
            panel.toggle(.commits)
          }
        ),
        ("opened_diff", { panel.openSelection(.commit) }),
        ("marked_viewed", { panel.toggleViewed("src/agent/StateHooks.swift") }),
        ("no_pull_request", { switchTo(.noPullRequest(published: true)) }),
        ("unpublished", { switchTo(.noPullRequest(published: false)) }),
        ("gh_unauthed", { switchTo(.unavailable(.ghUnauthed)) }),
        ("not_fetched", { switchTo(.notFetched) }),
        ("default_branch", { switchTo(.defaultBranch) }),
        ("emoji", { switchTo(.emoji) }),
      ])
  }
}
