import AppKit
import XCTest

@testable import Orbe

// CI の上でだけ走らせる診断。利用者の Mac では走らせない（本物の窓・本物のシートを画面に出し、アプリを前面にする）。
// 使い捨ての診断のブランチの `Tests/OrbeTests/` に置き、`ci-diagnostic.yml` の形にした CI で、このクラスだけを回す。
// u4 のブランチには入れない。
//
// 本物の違反を起こし、画面と前面の隔離がそのテストを落とすことを確かめる。隔離が記録した失敗を「期待する失敗」で
// 受けるので、隔離が働けばテストは通り、働かなければ「Expected failure … but none recorded」で落ちる。前提（窓が並んだ・
// シートが付いた・前面になった）が CI の上で成り立たなかったときは、「前提:」で始まる失敗で落ちる。
// 失敗を見分ける句（「ディスプレイの範囲」「本物のシート」「アクティベーションポリシー」「アプリが前面になった」）は、隔離の
// 失敗の文言に合わせる。どの失敗にも付く見出し（「画面と前面の隔離:」）に含まれる語は、見分けに使わない。
//
// 届く範囲を見るだけのテスト（testD）は、失敗を「在っても無くてもよい」で受け、どちらだったかはログの
// `Expected failure` の行の有無で読む。
//
// テストは名前の順に走る。testG は、始まりで前面でないことを前提にする。

@MainActor
final class ScreenBreachRealProbeTests: OrbeTestCase {
  private nonisolated(unsafe) static var kept: [NSWindow] = []

  private func expectBreach(_ phrase: String, strict: Bool = true) {
    let options = XCTExpectedFailure.Options()
    options.isStrict = strict
    options.issueMatcher = { $0.compactDescription.contains(phrase) }
    XCTExpectFailure("隔離が「\(phrase)」の失敗を記録する", options: options)
  }

  /// 条件が成り立つまで、アプリの出来事を配って待つ（時間では待たない。上限は成り立たないときの打ち切り）。
  private func wait(upTo seconds: TimeInterval = 10, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { spinOnce() }
    return condition()
  }

  /// ランループを 1 度回す。
  private func spinOnce() {
    if let event = NSApp.nextEvent(
      matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true)
    {
      NSApp.sendEvent(event)
    }
  }

  private func windowsOnDisplays() -> [NSWindow] {
    let displays = NSScreen.screens.map(\.frame)
    return NSApp.windows.filter { window in
      window.isVisible
        && displays.contains {
          let common = $0.intersection(window.frame)
          return common.width > 0 && common.height > 0
        }
    }
  }

  /// ディスプレイの左下の隅に置く、タイトルバーの無い 40×40 の窓。
  private func windowOnADisplay() throws -> NSWindow {
    let display = try XCTUnwrap(NSScreen.screens.first?.frame, "前提: ディスプレイが在る")
    let window = NSWindow(
      contentRect: NSRect(x: display.minX, y: display.minY, width: 40, height: 40),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  private func leaveTheFront() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    if NSApp.isActive {
      NSApp.deactivate()
      _ = wait { !NSApp.isActive }
    }
  }

  /// 本物の窓をディスプレイの中に並べたまま終わる（ランループは回さない。終わりの状態で見える）。
  func testA_ARealWindowLeftOnADisplayIsABreach() throws {
    expectBreach("ディスプレイの範囲")
    let window = try windowOnADisplay()
    window.orderFront(nil)
    Self.kept.append(window)
    print(
      "[probe] A isVisible=\(window.isVisible) frame=\(window.frame) "
        + "listed=\(NSApp.windows.contains(window)) displays=\(NSScreen.screens.map(\.frame))")
    XCTAssertTrue(window.isVisible, "前提: 窓が並んだ")
    // 検証者の追加: 手元の記録の道具（observe-screen.swift）と同じ読み方で、この窓がウィンドウサーバーの一覧に載るか。
    _ = wait(upTo: 2) { false }
    let list =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let own = list.filter {
      ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier
    }
    print(
      "[probe] A cgwindows owner=\(own.map { ($0[kCGWindowOwnerName as String] as? String) ?? "?" }) "
        + "bounds=\(own.map { ($0[kCGWindowBounds as String] as? NSDictionary) ?? [:] })")
  }

  func testB_TakeTheWindowDown() {
    Self.kept.forEach { $0.orderOut(nil) }
    Self.kept.removeAll()
  }

  /// 既存のテストの書き方（本文のローカル変数で持ち、後片付けで下ろす）でも、ランループが 1 度回れば落ちる。
  func testC_ALocalWindowTakenDownInTeardownIsABreachOnceTheRunLoopSpins() throws {
    expectBreach("ディスプレイの範囲")
    let window = try windowOnADisplay()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    window.orderFront(nil)
    spinOnce()
    print("[probe] C isVisible=\(window.isVisible) onDisplays=\(windowsOnDisplays().count)")
    XCTAssertTrue(window.isVisible, "前提: 窓が並んだ")
  }

  /// 届く範囲を見るだけ: 並べて、ランループを回さずに、後片付けで下ろす。落ちたかは、ログの `Expected failure` の行の有無で読む。
  func testD_ALocalWindowTakenDownWithoutASpinIsOnlyRecorded() throws {
    expectBreach("ディスプレイの範囲", strict: false)
    let window = try windowOnADisplay()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    window.orderFront(nil)
    print("[probe] D isVisible=\(window.isVisible) onDisplays=\(windowsOnDisplays().count)")
    XCTAssertTrue(window.isVisible, "前提: 窓が並んだ")
  }

  /// 本物のシートを出して閉じる。親の窓は画面の外に置く（シートの間は AppKit が画面の中へ動かす）。
  func testE_ARealSheetIsABreach() {
    expectBreach("本物のシート")
    // シートの間に動かされた親の窓と、シートの窓。ランループが回った時点で見えるかどうかは、ここでは問わない。
    expectBreach("ディスプレイの範囲", strict: false)
    let parent = NSWindow(
      contentRect: NSRect(origin: Self.offscreenOrigin, size: NSSize(width: 400, height: 300)),
      styleMask: [.borderless], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    let alert = NSAlert()
    alert.messageText = "probe"
    alert.addButton(withTitle: "OK")
    var response: NSApplication.ModalResponse?
    alert.beginSheetModal(for: parent) { response = $0 }
    XCTAssertTrue(wait { parent.attachedSheet != nil }, "前提: 本物のシートが付いた")
    print(
      "[probe] E attached=\(parent.attachedSheet != nil) parent.isVisible=\(parent.isVisible) "
        + "parent.frame=\(parent.frame) onDisplays=\(windowsOnDisplays().count)")
    if let sheet = parent.attachedSheet {
      parent.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    }
    XCTAssertTrue(wait { response != nil }, "前提: シートが閉じて応答が返った")
    parent.orderOut(nil)
    _ = wait { windowsOnDisplays().isEmpty }
    print("[probe] E after onDisplays=\(windowsOnDisplays().map { "\(type(of: $0)) \($0.frame)" })")
  }

  /// 本番コードが主窓を前面に出す経路（通知のクリック）を、本物の主窓で通る。
  func testF_TheProductionFrontRouteWithARealMainWindowIsABreach() {
    expectBreach("ディスプレイの範囲")
    // ポリシーが prohibited のままで前面になるかは、ここでは問わない。
    expectBreach("アプリが前面になった", strict: false)
    let wc = WindowController()
    addTeardownBlock {
      MainActor.assumeIsolated {
        wc.window.orderOut(nil)
        self.leaveTheFront()
      }
    }
    wc.openAutomationFromSystemNotification(-1)
    spinOnce()
    print(
      "[probe] F window.isVisible=\(wc.window.isVisible) frame=\(wc.window.frame) "
        + "isActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)")
    XCTAssertTrue(wc.window.isVisible, "前提: 主窓が並んだ")
  }

  /// 1 件の中でアプリを前面にして、自分で戻す。
  func testG_ActivationUndoneWithinTheTestIsABreach() {
    XCTAssertFalse(NSApp.isActive, "前提: 始まりで前面でない")
    expectBreach("アプリが前面になった")
    // ポリシーは終わりまでに戻すので、記録されない見込み。記録されても診断は落とさない。
    expectBreach("アクティベーションポリシー", strict: false)
    // 並べた窓は、前面になるのを待つ間にランループが回るので、記録される見込み。記録されなくても診断は落とさない。
    expectBreach("ディスプレイの範囲", strict: false)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    NSApplication.shared.setActivationPolicy(.accessory)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    let active = wait { NSApp.isActive }
    print("[probe] G isActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)")
    XCTAssertTrue(active, "前提: CI の上でアプリが前面になった")
    window.orderOut(nil)
    leaveTheFront()
    print("[probe] G after isActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)")
    XCTAssertFalse(NSApp.isActive, "前提: 前面から降りた")
  }

  /// アプリを前面にしたまま終わる（テスト自身は戻さない。戻すかどうかは隔離の側。次の testI が見る）。
  func testH_ActivationLeftIsABreach() {
    XCTAssertFalse(NSApp.isActive, "前提: 始まりで前面でない")
    expectBreach("アクティベーションポリシー")
    expectBreach("アプリが前面になった")
    // 並べた窓は、前面になるのを待つ間にランループが回るので、記録される見込み。記録されなくても診断は落とさない。
    expectBreach("ディスプレイの範囲", strict: false)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    NSApplication.shared.setActivationPolicy(.accessory)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    let active = wait { NSApp.isActive }
    print(
      "[probe] H isActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) "
        + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    XCTAssertTrue(active, "前提: CI の上でアプリが前面になった")
    window.orderOut(nil)
  }

  // 以下、検証者の追加（手直しの後の先頭で見る）。

  /// 違反したテスト（testH）の次のテストの始まりの状態と、前面でなくなるまでの時間を記録する。
  /// 手直しの確認: 始まりでポリシーが prohibited に戻っていること、前面でなくなること（落ちれば手直しが働いていない）。
  private func recordTheStateAfterABreach(_ label: String) {
    let policy = NSApp.activationPolicy()
    let activeAtStart = NSApp.isActive
    let begin = Date()
    let left = wait(upTo: 10) { !NSApp.isActive }
    print(
      "[probe] \(label) start policy=\(policy.rawValue) isActive=\(activeAtStart) "
        + "inactiveAfter=\(left ? String(format: "%.3f", Date().timeIntervalSince(begin)) : "never(10s)") "
        + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    XCTAssertEqual(policy, .prohibited, "手直しの確認: 違反の次のテストの始まりで、ポリシーが戻っている")
    XCTAssertTrue(left, "手直しの確認: 前面になったテストの後、アプリが前面でなくなる")
  }

  func testI_TheTestAfterAnActivationStartsRestored() {
    recordTheStateAfterABreach("I")
  }

  /// 本物の前面化の後、イベントを配送しない（ランループを回さない）間に `isActive` が真になるか。
  func testJ_ActivationWithoutDeliveringEvents() {
    XCTAssertFalse(NSApp.isActive, "前提: 始まりで前面でない")
    expectBreach("アクティベーションポリシー")
    // 終わりの確認の時点で isActive が真なら記録される。真になるかが、この診断で見ること。
    expectBreach("アプリが前面になった", strict: false)
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    let begin = Date()
    var activeWithoutDelivery = false
    while Date().timeIntervalSince(begin) < 3 {
      if NSApp.isActive {
        activeWithoutDelivery = true
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    let elapsed = Date().timeIntervalSince(begin)
    print(
      "[probe] J withoutDelivery isActive=\(activeWithoutDelivery) after=\(String(format: "%.3f", elapsed))")
    let activeWithDelivery = wait { NSApp.isActive }
    print(
      "[probe] J withDelivery isActive=\(activeWithDelivery) "
        + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    XCTAssertTrue(activeWithDelivery, "前提: CI の上でアプリが前面になった")
  }

  func testK_TheTestAfterTheSecondActivationStartsRestored() {
    recordTheStateAfterABreach("K")
  }
}
