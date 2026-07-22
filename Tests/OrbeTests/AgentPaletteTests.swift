import XCTest

@testable import Orbe

/// エージェント起動パレット（AgentPaletteModel・ドリルイン式）のロジック検証。
/// libghostty 非依存（@Observable モデルのみ・surface を生成しない）。
/// 入力欄を持たず常にカードがキーを捕捉する＝keyCode→意味メソッドの写像でモデルを駆動する。
@MainActor
final class AgentPaletteTests: XCTestCase {
  private let claude = AgentCLI(command: "claude", path: "/opt/homebrew/bin/claude")
  private let codex = AgentCLI(command: "codex", path: "/opt/homebrew/bin/codex")

  private func palette(_ agents: [AgentCLI], default command: String? = nil) -> AgentPaletteModel {
    let p = AgentPaletteModel(localization: LocalizationStore(language: .ja))
    p.setAgents(agents, defaultCommand: command)
    return p
  }

  private func key(_ p: AgentPaletteModel, _ keyCode: UInt16) {
    switch keyCode {
    case kDown: p.render.onDown()
    case kUp: p.render.onUp()
    case kReturn: p.render.onActivate()
    case kRight: _ = p.render.onRight()
    case kLeft: p.render.onLeft()
    case kEsc: p.render.onEscape()
    default: break
    }
  }
  private let kDown: UInt16 = 125, kUp: UInt16 = 126, kReturn: UInt16 = 36, kRight: UInt16 = 124,
    kLeft: UInt16 = 123, kEsc: UInt16 = 53

  // MARK: - 一覧: Enter で起動

  func testEnterLaunchesFirstAgent() {
    let p = palette([claude, codex])
    var launched: AgentCLI?
    p.onLaunch = { launched = $0 }
    key(p, kReturn)
    XCTAssertEqual(launched, claude, "Enter は選択中（先頭）のエージェントを起動")
  }

  func testMoveDownThenEnterLaunchesSecond() {
    let p = palette([claude, codex])
    var launched: AgentCLI?
    p.onLaunch = { launched = $0 }
    key(p, kDown)
    key(p, kReturn)
    XCTAssertEqual(launched, codex, "moveDown 後の Enter は 2 番目を起動")
  }

  func testMoveWrapsAround() {
    let p = palette([claude, codex])
    var launched: AgentCLI?
    p.onLaunch = { launched = $0 }
    key(p, kUp)  // 先頭で上 → 末尾へラップ
    key(p, kReturn)
    XCTAssertEqual(launched, codex, "先頭で moveUp すると末尾へラップ")
  }

  // MARK: - → で詳細メニューに潜る（デフォルトに設定）

  func testRightThenEnterSetsDefaultAndReturnsToList() {
    let p = palette([claude, codex])
    var setDefault: AgentCLI?
    var launched: AgentCLI?
    p.onSetDefault = { setDefault = $0 }
    p.onLaunch = { launched = $0 }
    key(p, kDown)  // codex を選択
    key(p, kRight)  // 詳細メニューへ（[デフォルトに設定]）
    key(p, kReturn)  // 設定 → 一覧へ戻る
    XCTAssertEqual(setDefault, codex, "詳細メニューの Enter は潜った先をデフォルトに設定")
    key(p, kReturn)  // 一覧に戻っている → 先頭を起動
    XCTAssertEqual(launched, claude, "設定後は一覧へ戻り Enter で起動できる")
  }

  func testLeftReturnsFromSubmenuToList() {
    let p = palette([claude, codex])
    var dismissed = false
    var launched: AgentCLI?
    p.onDismiss = { dismissed = true }
    p.onLaunch = { launched = $0 }
    XCTAssertNil(p.render.breadcrumb, "ルートは breadcrumb なし（ヘッダを描かない）")
    key(p, kRight)  // claude の詳細へ
    XCTAssertEqual(p.render.breadcrumb, "‹ claude", "詳細メニューは「‹ 親」")
    key(p, kLeft)  // ← で一覧へ戻る（閉じない）
    XCTAssertFalse(dismissed, "← は詳細→一覧で、パレットは閉じない")
    XCTAssertNil(p.render.breadcrumb, "一覧へ戻ると breadcrumb なしに復帰")
    key(p, kReturn)
    XCTAssertEqual(launched, claude, "一覧へ戻り Enter で起動")
  }

  func testEscFromSubmenuReturnsToListNotDismiss() {
    let p = palette([claude])
    var dismissed = false
    p.onDismiss = { dismissed = true }
    key(p, kRight)
    key(p, kEsc)
    XCTAssertFalse(dismissed, "詳細メニューの Esc は一覧へ戻るだけ")
  }

  func testEscFromListDismisses() {
    let p = palette([claude])
    var dismissed = false
    p.onDismiss = { dismissed = true }
    key(p, kEsc)
    XCTAssertTrue(dismissed, "一覧の Esc は onDismiss")
  }

  // MARK: - 空状態（検出ゼロ）

  func testEmptyStateSwallowsEnterAndDrillButEscDismisses() {
    let p = palette([])
    var launched: AgentCLI?
    var setDefault: AgentCLI?
    var dismissed = false
    p.onLaunch = { launched = $0 }
    p.onSetDefault = { setDefault = $0 }
    p.onDismiss = { dismissed = true }
    key(p, kReturn)
    key(p, kRight)
    XCTAssertNil(launched, "空状態の Enter は何も起動しない")
    XCTAssertNil(setDefault, "空状態では潜れない")
    key(p, kEsc)
    XCTAssertTrue(dismissed, "空状態でも Esc で閉じられる")
  }

  func testReloadWhileSubmenuAgentDisappearedReturnsToList() {
    // 開いたまま裏の再検出が届き、潜っていた対象が消えたら一覧へ戻る。
    let p = palette([claude, codex])
    var launched: AgentCLI?
    p.onLaunch = { launched = $0 }
    key(p, kDown)
    key(p, kRight)  // codex の詳細へ
    p.setAgents([claude], defaultCommand: "claude")  // 再検出で codex が消えた
    key(p, kReturn)
    XCTAssertEqual(launched, claude, "潜り先が消えたら一覧へ戻り、Enter は起動として働く")
  }
}
