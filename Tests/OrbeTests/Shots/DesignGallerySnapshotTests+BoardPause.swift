import AppKit
import XCTest

@testable import Orbe

/// ボードの gallery のうち、ノードごとの停止の段。
extension DesignGallerySnapshotTests {
  /// ノードごとの停止: 選んだ予定の取得（github）と、選んでいない処理（dedupe）を地図の space で止める。地図の行に停止の印と
  /// 「一時停止中」、カードの頭と「次回」に「一時停止中」、フッターの space は「再開」。
  func renderBoardPausedNodeSnapshots(
    write: (String, BoardModel, Language, NSSize) throws -> Void,
    board: ([AutomationSample]?, Int) -> BoardModel
  ) throws {
    for language in [Language.ja, .en] {
      let model = board(DesignSceneFixtures.boardMapSamples(), 0)
      model.automation.enterMap()
      model.automation.tapNode(key: "dedupe")
      model.automation.perform(.toggleNodePause)
      model.automation.tapNode(key: "github")
      model.automation.perform(.toggleNodePause)
      try write(
        "board_map_paused_node\(language == .ja ? "" : "_en").png", model, language,
        NSSize(width: 1440, height: 844))
    }
    // 予定のあるノードをすべて止めた自動化: 一覧の行と見出しの「次回」の位置に「ノードを一時停止中」。
    for language in [Language.ja, .en] {
      let all = board(DesignSceneFixtures.boardMapSamples(), 0)
      if let automation = all.automation.selectedAutomation {
        for node in automation.graph.nodes {
          guard case .scheduled = node.entity.trigger else { continue }
          _ = try all.automation.runner.pause(automation.id, nodeId: node.id, true)
        }
      }
      try write(
        "board_map_paused_scheduled\(language == .ja ? "" : "_en").png", all, language,
        NSSize(width: 1440, height: 844))
    }
    // workspace の設定がある自動化で、予定のあるノードをすべて止めた見出し: 「workspace：orbe」の行と「ノードを一時停止中」。
    for language in [Language.ja, .en] {
      let runner = DesignSceneFixtures.automationRunner(
        DesignSceneFixtures.boardWorkspaceSamples(),
        workspaces: DesignSceneFixtures.boardWorkspaces)
      let model = BoardModel(
        automation: BoardAutomationModel(runner: runner), widgets: [.automation])
      if let automation = runner.store.automations.first(where: { $0.name == "PR の確認" }) {
        model.automation.tap(automation.id)
        for node in automation.graph.nodes {
          guard case .scheduled = node.entity.trigger else { continue }
          _ = try runner.pause(automation.id, nodeId: node.id, true)
        }
      }
      try write(
        "board_workspace_paused_scheduled\(language == .ja ? "" : "_en").png", model, language,
        NSSize(width: 1440, height: 844))
    }
  }
}
