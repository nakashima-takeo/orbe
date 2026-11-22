import AppKit
import XCTest

/// 画面と前面の隔離（`ScreenIsolation`）が、破ったテストを実際に落とすことを固定する。
///
/// ここが崩れると、窓を画面に並べるテストや本物のシートを出すテストが緑のまま通り、`swift test` のたびに利用者の画面へ
/// 窓やシートが現れる。アクティベーションポリシーを変えたテストの後は、前面に出られるポリシーのまま残りのテストが走る。
/// テストが下ろさずに残した窓は、同じ実行の残りのテストの間、画面に残る。
/// 窓とシートの違反は、並べていないのに並んでいると答える窓と、手で出した通知で作る（画面には何も出ない）。ポリシーは
/// 本物を変えるが、画面にもフォーカスにも現れない。
@MainActor
final class ScreenIsolationTests: OrbeTestCase {
  /// テストの終わり（`tearDown` の後）まで生きている窓。テスト本体のローカル変数の窓は、終わりの確認より前に解放される。
  private var windowKeptToTheEnd: ClaimsShownWindow?

  /// 並んでいてディスプレイと重なる窓を残したまま終わったテストは、ランループを回していなくても落ちる。
  func testAWindowLeftOnADisplayFailsTheTest() throws {
    let display = try XCTUnwrap(NSScreen.screens.first, "前提: ディスプレイが在る")
    expectBreach("窓がディスプレイの範囲と重なって並んだ")
    windowKeptToTheEnd = ClaimsShownWindow(on: display)
  }

  /// ランループが回った時点でディスプレイと重なっていた窓は、テストの終わりまでに下ろしても、そのテストを落とす。
  func testAWindowOnADisplayWhenTheRunLoopSpinsFailsTheTestEvenIfLoweredByTheEnd() throws {
    let display = try XCTUnwrap(NSScreen.screens.first, "前提: ディスプレイが在る")
    expectBreach("窓がディスプレイの範囲と重なって並んだ")
    var shown = true
    let window = ClaimsShownWindow(on: display) { shown }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    shown = false
    _ = window
  }

  /// 本物のシートが出たテストは落ちる。
  func testARealSheetFailsTheTest() {
    expectBreach("本物のシートが出た")
    NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: NSWindow())
  }

  /// アクティベーションポリシーを変えたテストには失敗が記録され、ポリシーは始まりの値へ戻る。
  func testAChangedActivationPolicyIsRecordedAndRestored() {
    let app = NSApplication.shared
    XCTAssertEqual(app.activationPolicy(), .prohibited, "前提: テストの実行体のポリシーは prohibited")
    let screen = ScreenIsolation()
    // 隔離が戻すことを確かめるために、ポリシーだけを本物で変える。
    // swiftlint:disable:next test_screen_isolation
    app.setActivationPolicy(.accessory)
    var recorded: [String] = []
    screen.finish { recorded.append($0) }
    XCTAssertEqual(recorded.count, 1)
    XCTAssertTrue(recorded.first?.contains("アクティベーションポリシーが変わった") == true)
    XCTAssertEqual(app.activationPolicy(), .prohibited, "戻った")
  }

  /// テストが残した、ディスプレイと重なる窓について、隔離は失敗を記録し、その窓を下ろす。
  func testAWindowLeftOnADisplayIsRecordedAndOrderedOut() throws {
    let display = try XCTUnwrap(NSScreen.screens.first, "前提: ディスプレイが在る")
    let screen = ScreenIsolation()
    let window = ClaimsShownWindow(on: display)
    var recorded: [String] = []
    screen.finish { recorded.append($0) }
    XCTAssertEqual(recorded.count, 1)
    XCTAssertTrue(recorded.first?.contains("窓がディスプレイの範囲と重なって並んだ") == true)
    XCTAssertFalse(window.isShownOnADisplay, "下ろされた")
  }

  /// 隔離がこのテストに、`phrase` を含む失敗を記録することを期待する。記録しなければ、このテストが落ちる。
  private func expectBreach(_ phrase: String) {
    let options = XCTExpectedFailure.Options()
    options.issueMatcher = { $0.compactDescription.contains(phrase) }
    XCTExpectFailure("画面と前面の隔離が、このテストを落とす", options: options)
  }
}

/// 並べていない（OS の表示の並びに入れていない）のに、下ろされる（`orderOut`）までの間、`isShown` が true を返す限り
/// ディスプレイの中に並んでいると答える窓。
private final class ClaimsShownWindow: NSWindow {
  private let isShown: () -> Bool
  private var isOrderedOut = false

  init(on display: NSScreen, while isShown: @escaping () -> Bool = { true }) {
    self.isShown = isShown
    super.init(
      contentRect: NSRect(x: display.frame.midX, y: display.frame.midY, width: 200, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: true)
    isReleasedWhenClosed = false
  }

  override var isVisible: Bool { !isOrderedOut && isShown() }

  override func orderOut(_ sender: Any?) {
    isOrderedOut = true
    super.orderOut(sender)
  }
}
