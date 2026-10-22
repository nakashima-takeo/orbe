import SwiftUI
import XCTest

@testable import Orbe

/// ボードの flow。タブ行の横スクロール（`testBoardScroll`）と、自動化の部品のキー操作（`testBoardAutomation`）と、依頼の欄
/// （`testBoardRequest`）と、部品の並びの変化（`testBoardParts`）と、サブメニュー「通知」（`testBoardNotify`・
/// `testBoardNotifyLow`）。
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

  /// 部品の並び: 自動化の部品 → 外すと中央の一文だけ（フッターも出ない） → 置くと部品とフッターが戻る。
  func testBoardParts() throws {
    let model = BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardAutomationSamples())),
      parts: [.automation])
    try flow(
      "board_parts", size: NSSize(width: 1440, height: 844),
      render: {
        BoardRoot(
          model: model, translucency: ChromeTranslucency(),
          localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver())
      },
      steps: [
        ("start", {}),
        ("removed", { model.show([]) }),
        ("added", { model.show([.automation]) }),
      ])
  }

  /// ボードの自動化: 欄から ↓ で一覧の先頭 → ↓ で選ぶ → space で止める（行が末尾へ沈み、選択は付いていく）→ space で再開 →
  /// ⌘↵ で実行中 → ⌘↵ で赤の断り → ⌘⌫ で消え、同じ位置の行が選ばれる。
  func testBoardAutomation() throws {
    let model = BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardAutomationSamples())),
      parts: [.automation])
    let automation = model.automation
    try flow(
      "board_automation", size: NSSize(width: 1440, height: 844),
      render: {
        BoardRoot(
          model: model, translucency: ChromeTranslucency(),
          localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver())
      },
      steps: [
        ("start", {}),
        ("to_list", { automation.move(1) }),
        ("down", { automation.move(1) }),
        ("paused", { automation.perform(.togglePause) }),
        ("resumed", { automation.perform(.togglePause) }),
        ("run_now", { automation.perform(.flow(.ends)) }),
        ("run_refused", { automation.perform(.flow(.ends)) }),
        ("deleted", { automation.perform(.delete) }),
      ])
  }

  /// 地図と選んだ部品: 一覧で選ぶ（カードの欄は空）→ ↵ で先頭の部品 → ↑ で「通知」の段 → → で 3 択 → esc で段へ → ↓ で
  /// 部品 → 失敗した判定まで進む → 末尾で止まる → ⌘↵ で流れて実行中 → 流している途中の ⌘↵ は赤の断り → ← で一覧へ（地図の地と
  /// カードが消える）→ ↵ で同じ部品 → 一覧で別の自動化 → → で先頭の部品 → カードの「修正を依頼」（欄に書き出され焦点が欄へ）。
  func testBoardMap() throws {
    let model = BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardMapSamples())),
      parts: [.automation])
    let automation = model.automation
    let ja = LocalizationStore(language: .ja)
    try flow(
      "board_map", size: NSSize(width: 1440, height: 844),
      render: {
        BoardRoot(
          model: model, translucency: ChromeTranslucency(), localization: ja,
          fontResolver: ChromeFontResolver())
      },
      steps: [
        ("list", { automation.move(1) }),
        ("enter_first", { automation.enterMap() }),
        ("up_notify", { automation.moveInMap(-1) }),
        ("notify_open", { automation.openNotify() }),
        ("notify_back", { automation.closeNotify() }),
        ("down_part", { automation.moveInMap(1) }),
        ("to_contact", { for _ in 0..<11 { automation.moveInMap(1) } }),
        ("end_stops", { automation.moveInMap(1) }),
        ("flow", { automation.perform(.flow(.part)) }),
        ("flow_refused", { automation.perform(.flow(.part)) }),
        ("back_to_list", { automation.leaveMap() }),
        ("enter_same", { automation.enterMap() }),
        (
          "other_automation",
          {
            automation.leaveMap()
            automation.move(1)
          }
        ),
        ("enter_other_first", { automation.enterMap() }),
        ("ask_fix", { automation.draftFix(key: "note", l10n: ja) }),
      ])
  }

  /// 狭い窓: カードが地図の下へ回る。
  func testBoardMapNarrow() throws {
    let model = BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardMapSamples())),
      parts: [.automation])
    let automation = model.automation
    try flow(
      "board_map_narrow", size: NSSize(width: 1000, height: 844),
      render: {
        BoardRoot(
          model: model, translucency: ChromeTranslucency(),
          localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver())
      },
      steps: [
        ("list", { automation.move(1) }),
        ("contact", { automation.tapPart(key: "contact") }),
      ])
  }

  /// 依頼の欄: 入ると欄（強調の枠・行の選択と詳細が無い）→ 打つ → ↓ で一覧の先頭（欄は控えめな枠）→ ↑ で欄へ戻る →
  /// ↵ で欄が空 → ↑ で巡回して一覧の末尾 → ↓ で巡回して欄。秘書の口は閉包の差し替えで、本物の秘書・claude は
  /// 起きない。
  func testBoardRequest() throws {
    let model = BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardAutomationSamples())),
      parts: [.automation])
    let automation = model.automation
    automation.onAsk = { _ in nil }
    try flow(
      "board_request", size: NSSize(width: 1440, height: 844),
      render: {
        BoardRoot(
          model: model, translucency: ChromeTranslucency(),
          localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver())
      },
      steps: [
        ("start", {}),
        ("typed", { automation.requestText = "Slack の自分宛ての DM をタスクの候補にして" }),
        ("down_to_list", { automation.move(1) }),
        ("back_to_field", { automation.move(-1) }),
        ("sent", { automation.send() }),
        ("wrap_to_last", { automation.move(-1) }),
        ("wrap_to_field", { automation.move(1) }),
      ])
  }

  /// サブメニュー「通知」: 一覧の 2 行目の見出しの「通知」の行で開く（通知しないに印と選び）→ ↓ でメニューバーへ → ↵ で
  /// 決めて閉じ、「通知：メニューバー」に → 開き直すと印の行から → ↓ で通知センターへ → ← で何も変えずに閉じる。
  func testBoardNotify() throws {
    let model = BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardAutomationSamples())),
      parts: [.automation])
    let automation = model.automation
    try flow(
      "board_notify", size: NSSize(width: 1440, height: 844),
      render: {
        BoardRoot(
          model: model, translucency: ChromeTranslucency(),
          localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver())
      },
      steps: [
        (
          "start",
          {
            automation.move(1)
            automation.move(1)
          }
        ),
        ("opened", { automation.tapNotify() }),
        ("moved", { automation.moveNotify(1) }),
        ("chosen", { automation.chooseNotify(.menuBar) }),
        ("reopened", { automation.openNotify() }),
        ("moved_again", { automation.moveNotify(1) }),
        ("back", { automation.closeNotify() }),
      ])
  }

  /// 低く狭い窓: 末尾の行の「通知」の行で開く。フッターのキーが幅に収まるか。
  func testBoardNotifyLow() throws {
    let model = BoardModel(
      automation: BoardAutomationModel(
        runner: DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardAutomationSamples())),
      parts: [.automation])
    let automation = model.automation
    try flow(
      "board_notify_low", size: NSSize(width: 900, height: 340),
      render: {
        BoardRoot(
          model: model, translucency: ChromeTranslucency(),
          localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver())
      },
      steps: [
        ("last_row", { automation.move(-1) }),
        ("opened", { automation.tapNotify() }),
      ])
  }
}
