import XCTest

@testable import Orbe

/// オンボーディング系カード（言語選択・CLI 選択）の決定経路。行タップは選択移動で終わらず、
/// ↵ と同じ funnel（`activate()`）を通ってその場で確定する。
@MainActor
final class OnboardingActivateTests: XCTestCase {

  // MARK: - CLI 選択（OnboardingModel）

  func testRowTapSelectsAndBegins() {
    let m = OnboardingModel()
    m.agentCommands = ["claude", "codex", "agy"]
    var began = 0
    m.onBegin = { began += 1 }
    m.activate(at: 2)
    XCTAssertEqual(m.selected, 2, "タップ行がデフォルト選択になる")
    XCTAssertEqual(began, 1, "同じタップで確定まで進む")
  }

  func testRowTapBlockedWhileDetecting() {
    let m = OnboardingModel()
    m.agentCommands = ["claude"]
    m.detecting = true
    var began = 0
    m.onBegin = { began += 1 }
    m.activate(at: 0)
    XCTAssertEqual(began, 0, "検出中は ↵ と同様に確定しない")
  }

  func testRowTapBlockedWhileInstalling() {
    let m = OnboardingModel()
    m.agentCommands = ["claude", "codex"]
    m.beginInstalling()
    var began = 0
    m.onBegin = { began += 1 }
    m.activate(at: 1)
    XCTAssertEqual(began, 0, "導入フェーズには選択行が無く確定もしない")
  }

  func testRowTapOutOfRangeIsSafe() {
    let m = OnboardingModel()
    m.agentCommands = ["claude"]
    var began = 0
    m.onBegin = { began += 1 }
    m.activate(at: 5)
    XCTAssertEqual(began, 0)
    XCTAssertEqual(m.selected, 0)
  }

  // MARK: - 言語選択（LanguageSelectModel）

  func testLanguageRowTapConfirmsThatRow() {
    let m = LanguageSelectModel(current: Language.allCases[0])
    var confirmed: Language?
    m.onConfirm = { confirmed = $0 }
    let target = Language.allCases.count - 1
    m.activate(at: target)
    XCTAssertEqual(m.selected, target)
    XCTAssertEqual(confirmed, Language.allCases[target], "タップした行の言語で確定する")
  }

  func testLanguageRowTapOutOfRangeIsSafe() {
    let m = LanguageSelectModel(current: Language.allCases[0])
    var confirmed: Language?
    m.onConfirm = { confirmed = $0 }
    m.activate(at: 99)
    XCTAssertNil(confirmed)
    XCTAssertEqual(m.selected, 0)
  }
}
