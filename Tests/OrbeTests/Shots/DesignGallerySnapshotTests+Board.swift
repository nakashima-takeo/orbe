import SwiftUI
import XCTest

@testable import Orbe

/// ボードの gallery。Home のタブ行（左端に固定のボードのセル）を、ボード選択中・タブ選択中・タブが溢れて横スクロールへ
/// 回る段で撮り、部品を持たないボードの一文と、自動化の部品（見本『Home 自動化』。依頼の欄を含む）を撮る。タブ行の見本は
/// §5 Tab 契約・§5.1 TabBar（ボードのセルは単独タブの器）。
extension DesignGallerySnapshotTests {
  func renderBoardSnapshots(dir: URL) throws {
    let rowStage = NSSize(width: 640, height: 520)
    let homeTabs = TabStrip(
      titles: ["秘書", "claude", "~/notes"], glyphs: [.working, .done, nil])

    let boardSelected = homeRow(homeTabs, selection: .board)
    try writePNG(
      homeBand(boardSelected, size: rowStage), size: rowStage,
      name: "statusrow_board_selected.png", dir: dir)
    try writePNG(
      homeBand(boardSelected, size: rowStage).environment(\.windowIsMain, false), size: rowStage,
      name: "statusrow_board_selected_inactive.png", dir: dir)

    let tabSelected = homeRow(homeTabs, selection: .tab(1))
    tabSelected.location = [.dim("~/Library/Application Support/dev.orbe.app.dev/home")]
    tabSelected.faceDots = .init(editor: .off, terminal: .focus)
    try writePNG(
      homeBand(tabSelected, size: rowStage), size: rowStage, name: "statusrow_board_tab.png",
      dir: dir)

    // 床 40 でも収まらず横スクロールへ回る段。ボードのセルはスクロールの外で左端に残る。
    let glyphCycle: [AgentStateIcon.Kind?] = [.working, .waiting, .done, nil]
    let overflow = homeRow(
      TabStrip(
        titles: (0..<16).map { "task-\($0)" },
        glyphs: (0..<16).map { glyphCycle[$0 % glyphCycle.count] }),
      selection: .board)
    try writePNG(
      homeBand(overflow, size: rowStage), size: rowStage, name: "statusrow_board_overflow.png",
      dir: dir)

    try writePNG(
      BoardRoot(
        model: BoardModel(
          automation: BoardAutomationModel(
            runner: DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardAutomationFile())),
          parts: []),
        translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
        fontResolver: ChromeFontResolver()),
      size: NSSize(width: 640, height: 480), name: "board_empty.png", dir: dir)

    try renderBoardAutomationSnapshots(dir: dir)
  }

  /// 見本『Home 自動化』のボードの面（窓の飾りとタブ行を除いた 1440×844）。
  private func renderBoardAutomationSnapshots(dir: URL) throws {
    let size = NSSize(width: 1440, height: 844)
    func write(
      _ name: String, _ model: BoardModel, _ language: Language = .ja, _ size: NSSize = size
    ) throws {
      try writePNG(
        BoardRoot(
          model: model, translucency: ChromeTranslucency(),
          localization: LocalizationStore(language: language), fontResolver: ChromeFontResolver()),
        size: size, name: name, dir: dir)
    }
    /// 一覧の `row` 行目（0 始まり）を選んだ状態。0 件なら欄のまま。
    func board(_ file: AutomationsFile? = nil, row: Int = 0) -> BoardModel {
      let model = BoardModel(
        automation: BoardAutomationModel(
          runner: DesignSceneFixtures.automationRunner(
            file ?? DesignSceneFixtures.boardDesignFile())),
        parts: [.automation])
      for _ in 0...row { model.automation.move(1) }
      return model
    }

    // 並びは 前回が失敗（Backlog）→ Slack → GitHub → まだ回っていない → 止めている（Gmail）。
    try write("board_automation.png", board(row: 1))
    try write("board_automation_en.png", board(row: 1), .en)
    try write("board_automation_failed.png", board())
    try write("board_automation_quiet.png", board(row: 2))
    try write("board_automation_never_ran.png", board(row: 3))
    try write("board_automation_paused.png", board(row: 4))

    let field = board()
    field.automation.go(.request)
    try write("board_automation_field.png", field)
    try write("board_automation_field_en.png", field, .en)

    let running = board(row: 1)
    running.automation.perform(.runNow)
    running.automation.perform(.runNow)
    try write("board_automation_running.png", running)

    try write("board_automation_zero.png", board(DesignSceneFixtures.automationEmptyFile()))

    let long = board(DesignSceneFixtures.boardAutomationLongFile())
    try write("board_automation_long_agent.png", long)
    long.automation.move(1)
    long.automation.move(1)
    try write("board_automation_long_command.png", long)

    try write("board_automation_narrow.png", board(row: 1), .ja, NSSize(width: 800, height: 600))
    try write("board_automation_narrow_failed.png", board(), .ja, NSSize(width: 800, height: 600))

    // 見本『段の多い例』『一番単純な例』。どちらも回の記録から読み替えた本物の値で描く。
    let examples = DesignSceneFixtures.boardAutomationFile([
      DesignSceneFixtures.boardStepsExample(), DesignSceneFixtures.boardSimpleExample(),
      DesignSceneFixtures.boardDailyNoteExample(), DesignSceneFixtures.boardMergedPostExample(),
    ])
    try write("board_automation_steps.png", board(examples))
    try write("board_automation_simple.png", board(examples, row: 1))
    // 見本『日報の下書き』（取得元も段も無い出力先コマンド）と、取得元のある出力先コマンド。
    try write("board_automation_command.png", board(examples, row: 2))
    try write("board_automation_command_en.png", board(examples, row: 2), .en)
    try write("board_automation_command_sourced.png", board(examples, row: 3))
    try renderBoardReportSnapshots(write: write, board: { board($0, row: $1) })
    try renderBoardRequestSnapshots(write: write, board: { board($0) })
    try renderBoardNotifySnapshots(write: write, board: { board($0, row: $1) })
  }

  /// サブメニュー「通知」: 通知しない自動化で開いた直後（印と選びが同じ行）・メニューバーの自動化で通知センターへ選びを
  /// 動かした姿・低い窓の末尾の行で開いて部品の下端の内側へずれた姿。
  private func renderBoardNotifySnapshots(
    write: (String, BoardModel, Language, NSSize) throws -> Void,
    board: (AutomationsFile?, Int) -> BoardModel
  ) throws {
    let size = NSSize(width: 1440, height: 844)
    for language in [Language.ja, .en] {
      let suffix = language == .ja ? "" : "_en"
      let off = board(nil, 1)
      off.automation.openNotify()
      try write("board_notify\(suffix).png", off, language, size)
    }

    let reports = DesignSceneFixtures.boardAutomationFile([
      DesignSceneFixtures.boardStepsNotifyExample(), DesignSceneFixtures.boardReportExample(),
    ])
    let menuBar = board(reports, 1)
    menuBar.automation.openNotify()
    menuBar.automation.moveNotify(1)
    try write("board_notify_moved.png", menuBar, .ja, size)

    let low = board(nil, 4)
    low.automation.openNotify()
    try write("board_notify_low.png", low, .ja, NSSize(width: 1000, height: 400))
  }

  /// 見本 B2『開いている PR の要約』（出力先は報告・通知はメニューバー）と、累計と通知の注記が並ぶタスク候補。通知先が
  /// 通知センターの報告。
  private func renderBoardReportSnapshots(
    write: (String, BoardModel, Language, NSSize) throws -> Void,
    board: (AutomationsFile?, Int) -> BoardModel
  ) throws {
    let size = NSSize(width: 1440, height: 844)
    let reports = DesignSceneFixtures.boardAutomationFile([
      DesignSceneFixtures.boardStepsNotifyExample(), DesignSceneFixtures.boardReportExample(),
    ])
    try write("board_automation_report.png", board(reports, 1), .ja, size)
    try write("board_automation_report_en.png", board(reports, 1), .en, size)
    try write("board_automation_steps_notify.png", board(reports, 0), .ja, size)
    let center = DesignSceneFixtures.boardAutomationFile([
      DesignSceneFixtures.boardReportNotificationCenterExample()
    ])
    try write("board_automation_report_center.png", board(center, 0), .ja, size)
    try write("board_automation_report_center_en.png", board(center, 0), .en, size)
  }

  /// 依頼の欄: 文字あり（欄に焦点・フッターが欄のキー）・断り 2 種。秘書の口は閉包の差し替えで、本物の秘書・claude は起きない。
  private func renderBoardRequestSnapshots(
    write: (String, BoardModel, Language, NSSize) throws -> Void,
    board: (AutomationsFile?) -> BoardModel
  ) throws {
    let size = NSSize(width: 1440, height: 844)

    for language in [Language.ja, .en] {
      let suffix = language == .ja ? "" : "_en"
      let typed = board(nil)
      typed.automation.go(.request)
      typed.automation.requestText =
        language == .ja
        ? "平日の18時に、その日マージした PR の一覧を自分宛てに送る"
        : "Every weekday at 18:00, send me the PRs merged that day"
      try write("board_request_typed\(suffix).png", typed, language, size)
    }

    let missing = board(nil)
    missing.automation.onAsk = { _ in .claudeMissing }
    missing.automation.go(.request)
    missing.automation.requestText = "Slack の自分宛ての DM をタスクの候補にして"
    missing.automation.send()
    try write("board_request_claude_missing.png", missing, .ja, size)

    let gone = board(nil)
    try gone.automation.runner.delete(try XCTUnwrap(gone.automation.selectedAutomation?.id))
    gone.automation.askFix()
    try write("board_request_fix_gone.png", gone, .ja, size)
  }

  private func homeRow(_ strip: TabStrip, selection: StatusRowModel.Selection) -> StatusRowModel {
    let model = StatusRowModel()
    model.workspace = "Home"
    model.boardLabel = "Home"
    model.strip = strip
    model.selection = selection
    model.rollup = [("working", 1), ("done", 1)]
    return model
  }

  private func homeBand(_ model: StatusRowModel, size: NSSize) -> some View {
    ZStack(alignment: .top) {
      BackgroundGlow()
      StatusRowView(model: model).frame(width: size.width, height: Chrome.barHeight)
    }
    .frame(width: size.width, height: size.height, alignment: .top)
  }
}
