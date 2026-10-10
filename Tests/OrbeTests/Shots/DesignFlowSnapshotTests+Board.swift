import SwiftUI
import XCTest

@testable import Orbe

/// ボードの flow。タブ行の横スクロール（`testBoardScroll`）と、自動追加の部品のキー操作（`testBoardIntake`）。
/// タブ行の横スクロール: 選択が右端のタブへ移るとタブ列だけがスクロールし、ボードのセルは左端に残る。
/// スクロール位置は描画を跨いで持つ状態なので、1 枚の host を使い回して選択を変えるたびに撮る（`flow` は毎回 host を
/// 作り直すので、スクロールが出ない）。
extension DesignFlowSnapshotTests {
  func testBoardScroll() throws {
    let size = NSSize(width: 640, height: 112)
    let glyphCycle: [AgentStateIcon.Kind?] = [.working, .waiting, .done, nil]
    let model = StatusRowModel()
    model.workspace = "Home"
    model.boardLabel = "Home"
    model.strip = TabStrip(
      titles: (0..<16).map { "task-\($0)" },
      glyphs: (0..<16).map { glyphCycle[$0 % glyphCycle.count] })
    model.selection = .board

    let appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingView(
      rootView: ZStack(alignment: .top) {
        BackgroundGlow()
        StatusRowView(model: model).frame(width: size.width, height: Chrome.barHeight)
      }
      .frame(width: size.width, height: size.height, alignment: .top))
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = appearance
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host

    let dir = previewDir("flows")
    let steps: [(String, StatusRowModel.Selection)] = [
      ("board", .board), ("last_tab", .tab(15)), ("board_again", .board), ("first_tab", .tab(0)),
    ]
    for (idx, (label, selection)) in steps.enumerated() {
      model.selection = selection
      host.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      let url = dir.appendingPathComponent(String(format: "board_scroll_%02d_%@.png", idx, label))
      try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }

  /// ボードの自動追加: ↓ で選ぶ → space で止める（行が末尾へ沈み、選択は付いていく）→ space で再開 → ↵ で実行中… → ↵ で赤の
  /// 断り → ⌘⌫ で消え、同じ位置の行が選ばれる。
  func testBoardIntake() throws {
    let model = BoardModel(
      intake: BoardIntakeModel(
        runner: DesignSceneFixtures.intakeRunner(DesignSceneFixtures.boardIntakeFile())))
    let intake = model.intake
    try flow(
      "board_intake", size: NSSize(width: 1440, height: 826),
      render: {
        BoardRoot(
          model: model, translucency: ChromeTranslucency(),
          localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver())
      },
      steps: [
        ("start", {}),
        ("down", { intake.move(1) }),
        ("paused", { intake.perform(.togglePause) }),
        ("resumed", { intake.perform(.togglePause) }),
        ("run_now", { intake.perform(.runNow) }),
        ("run_refused", { intake.perform(.runNow) }),
        ("deleted", { intake.perform(.delete) }),
      ])
  }
}
