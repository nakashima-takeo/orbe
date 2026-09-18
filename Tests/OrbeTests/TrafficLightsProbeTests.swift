import AppKit
import XCTest

@testable import Orbe

/// 殻（`AppShell`）が付けた probe が、信号機（close ボタン）が chrome の上にあるか・あるならその
/// 縦位置を実窓から読み、`StatusRowModel.trafficLights` へ書くことを固定する。ネイティブ・
/// フルスクリーンで macOS が信号機を上端の帯（別窓）へ引き取る/返す動きを、実際にボタンを別窓へ
/// 移し替えて再現する。
///
/// 壊れると何が起きるか。`.absent` を読み落とすと、フルスクリーン中の上段左に信号機ぶんの柱
/// （80pt）が誰も居ないまま空き続ける——workspace 名が画面端から遠く離れた空白の穴の右に浮く。
/// 逆に窓状態で `.absent` へ転ぶと、上段テキストが信号機の下へ潜り込む。移っても `superview` は
/// 残るので、在否は「自窓に居るか」でしか見分けられない。
final class TrafficLightsProbeTests: OrbeTestCase {
  private var bands: [NSWindow] = []

  override func setUp() {
    super.setUp()
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay を出さない。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  override func tearDown() {
    bands.forEach { $0.orderOut(nil) }
    bands.removeAll()
    super.tearDown()
  }

  /// probe は `DispatchQueue.main.async` で書くので、次の run loop まで回して読む。
  private func settle() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  }

  /// macOS がフルスクリーンで信号機を引き取る先の帯に相当する別窓。
  private func band() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 32),
      styleMask: [.borderless], backing: .buffered, defer: false)
    bands.append(window)
    return window
  }

  private func launched() -> WindowController {
    let wc = WindowController()
    wc.window.contentView?.layoutSubtreeIfNeeded()
    settle()
    return wc
  }

  /// 窓状態では信号機は chrome の上にあり、その縦位置は上段の帯の中にある。
  func testProbeReadsTrafficLightsOverChromeInWindowedState() throws {
    let wc = launched()

    guard case .over(let centerY) = wc.statusModel.trafficLights else {
      return XCTFail("窓状態の製品窓では信号機は chrome の上にある: \(wc.statusModel.trafficLights)")
    }
    XCTAssertGreaterThan(centerY, 0, "信号機の中央は chrome 上端より下")
    XCTAssertLessThan(centerY, Chrome.headerHeight, "信号機の中央は上段の帯に収まる")
  }

  /// フルスクリーンで信号機が別窓の帯へ移ると `.absent`（`superview` は残ったまま）。
  func testProbeReportsAbsentWhenTrafficLightsMoveToAnotherWindow() throws {
    let wc = launched()
    let close = try XCTUnwrap(wc.window.standardWindowButton(.closeButton))

    band().contentView?.addSubview(close)
    XCTAssertNotNil(close.superview, "帯へ移っても superview は残る（在否を superview では測れない）")
    NotificationCenter.default.post(
      name: NSWindow.didEnterFullScreenNotification, object: wc.window)
    settle()

    XCTAssertEqual(wc.statusModel.trafficLights, .absent)
  }

  /// フルスクリーンを抜けて信号機が戻れば、縦位置も入る前と同じに戻る。
  func testProbeReadsTrafficLightsAgainWhenTheyReturnOnExitFullScreen() throws {
    let wc = launched()
    let windowed = wc.statusModel.trafficLights
    let close = try XCTUnwrap(wc.window.standardWindowButton(.closeButton))
    band().contentView?.addSubview(close)
    NotificationCenter.default.post(
      name: NSWindow.didEnterFullScreenNotification, object: wc.window)
    settle()

    wc.window.contentView?.addSubview(close)
    NotificationCenter.default.post(
      name: NSWindow.didExitFullScreenNotification, object: wc.window)
    settle()

    XCTAssertEqual(wc.statusModel.trafficLights, windowed)
  }
}
