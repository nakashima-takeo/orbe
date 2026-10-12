import SwiftUI
import XCTest

@testable import Orbe

/// ボードの gallery。Home のタブ行（左端に固定のボードのセル）を、ボード選択中・タブ選択中・タブが溢れて横スクロールへ
/// 回る段で撮り、部品を持たないボードの一文と、自動追加の部品（見本『Home』。依頼の欄を含む）を撮る。タブ行の見本は §5 Tab 契約・§5.1 TabBar
/// （ボードのセルは単独タブの器）。
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

  /// 見本『Home』のボードの面（窓の chrome とタブ行を除いた 1440×826）。
  private func renderBoardAutomationSnapshots(dir: URL) throws {
    func write(
      _ name: String, _ model: BoardModel, _ language: Language = .ja,
      _ size: NSSize = NSSize(width: 1440, height: 826)
    ) throws {
      try writePNG(
        BoardRoot(
          model: model, translucency: ChromeTranslucency(),
          localization: LocalizationStore(language: language), fontResolver: ChromeFontResolver()),
        size: size, name: name, dir: dir)
    }
    /// 一覧の先頭の行を選んだ状態（見本『Home』と突き合わせる。0 件なら欄のまま）。
    func board(_ file: AutomationsFile? = nil) -> BoardModel {
      let model = BoardModel(
        automation: BoardAutomationModel(
          runner: DesignSceneFixtures.automationRunner(
            file ?? DesignSceneFixtures.boardAutomationFile())),
        parts: [.automation])
      model.automation.move(1)
      return model
    }

    try write("board_automation.png", board())
    try write("board_automation_en.png", board(), .en)

    let paused = board()
    paused.automation.move(1)
    paused.automation.move(1)
    paused.automation.move(1)
    try write("board_automation_paused.png", paused)

    let running = board()
    running.automation.move(1)
    running.automation.perform(.runNow)
    running.automation.perform(.runNow)
    try write("board_automation_running.png", running)

    try write("board_automation_zero.png", board(DesignSceneFixtures.automationEmptyFile()))

    let long = board(DesignSceneFixtures.boardAutomationLongFile())
    try write("board_automation_long_agent.png", long)
    long.automation.move(1)
    long.automation.move(1)
    try write("board_automation_long_command.png", long)

    try write("board_automation_narrow.png", board(), .ja, NSSize(width: 800, height: 480))

    try renderBoardRequestSnapshots(write: write, board: board)
  }

  /// 依頼の欄: 文字あり（欄に焦点・フッターが欄のキー）・断り 2 種。秘書の口は閉包の差し替えで、本物の秘書・claude は起きない。
  private func renderBoardRequestSnapshots(
    write: (String, BoardModel, Language, NSSize) throws -> Void,
    board: (AutomationsFile?) -> BoardModel
  ) throws {
    let size = NSSize(width: 1440, height: 826)

    for language in [Language.ja, .en] {
      let suffix = language == .ja ? "" : "_en"
      let typed = board(nil)
      typed.automation.go(.request)
      typed.automation.requestText =
        language == .ja ? "Slack の自分宛ての DM をタスクの候補にして" : "Turn my Slack DMs into task candidates"
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
