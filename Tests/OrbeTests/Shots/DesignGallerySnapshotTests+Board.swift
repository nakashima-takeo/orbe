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
      BoardEmptyView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChromeTranslucency().baseFill)
        .environment(\.localization, LocalizationStore(language: .ja)),
      size: NSSize(width: 640, height: 480), name: "board_empty.png", dir: dir)

    try renderBoardIntakeSnapshots(dir: dir)
  }

  /// 見本『Home』のボードの面（窓の chrome とタブ行を除いた 1440×826）。
  private func renderBoardIntakeSnapshots(dir: URL) throws {
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
    func board(_ file: IntakesFile? = nil) -> BoardModel {
      BoardModel(
        intake: BoardIntakeModel(
          runner: DesignSceneFixtures.intakeRunner(file ?? DesignSceneFixtures.boardIntakeFile())))
    }

    try write("board_intake.png", board())
    try write("board_intake_en.png", board(), .en)

    let paused = board()
    paused.intake.move(1)
    paused.intake.move(1)
    paused.intake.move(1)
    try write("board_intake_paused.png", paused)

    let running = board()
    running.intake.move(1)
    running.intake.perform(.runNow)
    running.intake.perform(.runNow)
    try write("board_intake_running.png", running)

    try write("board_intake_zero.png", board(DesignSceneFixtures.intakeEmptyFile()))

    let long = board(DesignSceneFixtures.boardIntakeLongFile())
    try write("board_intake_long_agent.png", long)
    long.intake.move(1)
    long.intake.move(1)
    try write("board_intake_long_command.png", long)

    try write("board_intake_narrow.png", board(), .ja, NSSize(width: 800, height: 480))

    try renderBoardRequestSnapshots(write: write, board: board)
  }

  /// 依頼の欄: 文字あり（欄に焦点・フッターが欄のキー）・断り 2 種。秘書の口は閉包の差し替えで、本物の秘書・claude は起きない。
  private func renderBoardRequestSnapshots(
    write: (String, BoardModel, Language, NSSize) throws -> Void,
    board: (IntakesFile?) -> BoardModel
  ) throws {
    let size = NSSize(width: 1440, height: 826)

    for language in [Language.ja, .en] {
      let suffix = language == .ja ? "" : "_en"
      let typed = board(nil)
      typed.intake.go(.request)
      typed.intake.requestText =
        language == .ja ? "Slack の自分宛ての DM をタスクの候補にして" : "Turn my Slack DMs into task candidates"
      try write("board_request_typed\(suffix).png", typed, language, size)
    }

    let missing = board(nil)
    missing.intake.onAsk = { _ in .claudeMissing }
    missing.intake.go(.request)
    missing.intake.requestText = "Slack の自分宛ての DM をタスクの候補にして"
    missing.intake.send()
    try write("board_request_claude_missing.png", missing, .ja, size)

    let gone = board(nil)
    try gone.intake.runner.delete(try XCTUnwrap(gone.intake.selected?.id))
    gone.intake.askFix()
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
