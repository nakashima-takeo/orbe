import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 本体が空のときの表示——出すものが無いときは、本体の中央に見出しと案内の一文を出す。
///
/// 壊れると何が起きるか: 変更ファイルが 0 件の PR を開くと本体が空白のままで、読み込み中か壊れているかの見分けが付かない。
@MainActor
final class EditorEmptyViewTests: OrbeTestCase {
  /// 中身が読めて変更ファイルが無い PR の画面は、本体を空白のままにせず、見出し「変更ファイルなし」と案内の一文を出す
  /// （文言と姿は flow `editor_pr` の `no_files` が撮る）。
  func testAPullRequestWithoutChangedFilesShowsTheMessage() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try PrFixtures.scene(.noFiles, queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "PR の中身が揃う")
    let pane = scene.pane
    pane.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.faceHost.rootView.content, .empty(.pullRequest), "前提: 本体は空")
    pumpMain(until: { (try? self.isBlank(pane.faceHost)) == false }, "本体に見出しと一文が出る")
  }

  /// `view` が何も描かない（全画素が透明）。
  private func isBlank(_ view: NSView) throws -> Bool {
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let data = try XCTUnwrap(rep.bitmapData)
    return !(0..<(rep.bytesPerRow * rep.pixelsHigh)).contains { data[$0] != 0 }
  }
}
