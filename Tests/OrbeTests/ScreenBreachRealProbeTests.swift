import AppKit
import XCTest

@testable import Orbe

// CI の上でだけ走らせる診断。利用者の Mac では走らせない（本物の窓・本物のシートを画面に出し、アプリを前面にする）。
// 使い捨ての診断のブランチの `Tests/OrbeTests/` に置き、同じフォルダの `ci.yml` を `.github/workflows/ci.yml` にして、
// このクラスだけを回す。PR #456 のブランチには入れない。
//
// PR #456 の隔離（終わりに、ポリシーを戻し、前面なら deactivate を 1 回呼び、このテストの間に増えてディスプレイと重なる窓を
// orderOut で下ろす）を、本物の違反で確かめる。
//
// - 違反を起こすテストは、隔離が記録する失敗を「期待する失敗」で受ける。隔離が落とさなければ「Expected failure … but none
//   recorded」で落ちる。
// - 違反の次のテストは、始まりの状態を `[probe]` の行に出し、条件が崩れていれば落ちる。
// - 前提（窓が並んだ・シートが付いた・前面になった）が CI の上で成り立たなかったときは、「前提:」で始まる失敗で落ちる。
//
// テストは名前の順に走る。

@MainActor
final class ScreenBreachRealProbeTests: OrbeTestCase {
  private nonisolated(unsafe) static var keptWindow: NSWindow?
  private nonisolated(unsafe) static var keptSheetParent: NSWindow?
  private nonisolated(unsafe) static var keptAlert: NSAlert?
  private nonisolated(unsafe) static var sheetResponse: NSApplication.ModalResponse?
  private nonisolated(unsafe) static var deactivateCallsAtStartOfI: Int?

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

  /// AppKit の答え（隔離と同じ `isShownOnADisplay`）で、ディスプレイと重なる窓。
  private func windowsOnDisplays() -> [NSWindow] {
    NSApp.windows.filter(\.isShownOnADisplay)
  }

  /// ウィンドウサーバーの答えで、画面に載っているこの実行体の窓のうち、ディスプレイと面積を持って重なるもの。
  private func serverWindowsOnDisplays() -> [String] {
    let pid = ProcessInfo.processInfo.processIdentifier
    let list =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let displays = NSScreen.screens.map(\.frame)
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    return list.compactMap { info in
      guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
        let dict = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: dict),
        bounds.width > 0, bounds.height > 0
      else { return nil }
      // CG の座標は主ディスプレイの左上が原点。AppKit の座標（左下が原点）へ、主ディスプレイの高さで反転して比べる。
      let flipped = CGRect(
        x: bounds.minX, y: mainHeight - bounds.maxY, width: bounds.width, height: bounds.height)
      let overlaps = displays.contains {
        let common = $0.intersection(flipped)
        return common.width > 0 && common.height > 0
      }
      return overlaps ? "\(info[kCGWindowNumber as String] ?? "?") \(flipped)" : nil
    }
  }

  private func describe(_ windows: [NSWindow]) -> String {
    "\(windows.map { "\(type(of: $0)) \($0.frame)" })"
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

  /// 違反の次のテストの始まりで、ディスプレイと重なる窓が無いことを確かめる（待たずに見る）。
  /// ウィンドウサーバーの答えは、始まりの時点と、出来事を配って空になるまでの時間を出す（合否には使わない）。
  private func recordNoWindowOnADisplayAtStart(_ label: String, kept: [NSWindow?]) {
    let appKit = windowsOnDisplays()
    let server = serverWindowsOnDisplays()
    let keptVisible = kept.compactMap { $0 }.map(\.isVisible)
    let begin = Date()
    let serverEmpty = wait(upTo: 3) { serverWindowsOnDisplays().isEmpty }
    print(
      "[probe] \(label) start appKitOnDisplays=\(describe(appKit)) serverOnDisplays=\(server) "
        + "keptVisible=\(keptVisible) "
        + "serverEmptyAfter=\(serverEmpty ? String(format: "%.3f", Date().timeIntervalSince(begin)) : "never(3s)")")
    XCTAssertTrue(appKit.isEmpty, "確認: 違反の次のテストの始まりに、ディスプレイと重なる窓が無い")
    XCTAssertFalse(keptVisible.contains(true), "確認: 残した窓は下ろされている")
  }

  // MARK: 本物の窓を残す

  /// 本物の窓をディスプレイの中に並べたまま終わる。テスト自身は下ろさない（下ろすのは隔離。次の testB が見る）。
  func testA_ARealWindowLeftOnADisplayIsABreach() throws {
    expectBreach("ディスプレイの範囲")
    let window = try windowOnADisplay()
    window.orderFront(nil)
    Self.keptWindow = window
    print(
      "[probe] A isVisible=\(window.isVisible) frame=\(window.frame) "
        + "listed=\(NSApp.windows.contains(window)) displays=\(NSScreen.screens.map(\.frame))")
    XCTAssertTrue(window.isVisible, "前提: 窓が並んだ")
  }

  func testB_TheTestAfterALeftWindowStartsWithNoWindowOnADisplay() {
    recordNoWindowOnADisplayAtStart("B", kept: [Self.keptWindow])
    Self.keptWindow = nil
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

  // MARK: 本物のシートを残す

  /// 本物のシートを出したまま終わる。テスト自身は応答も下ろしもしない（次の testE が見る）。
  /// 親の窓は画面の外に置く（シートの間は AppKit が画面の中へ動かす）。
  func testD_ARealSheetLeftIsABreach() {
    expectBreach("本物のシート")
    // シートの間に動かされた親の窓と、シートの窓。終わりの時点で並んでいれば記録される見込み。記録されなくても診断は落とさない。
    expectBreach("ディスプレイの範囲", strict: false)
    let parent = NSWindow(
      contentRect: NSRect(origin: Self.offscreenOrigin, size: NSSize(width: 400, height: 300)),
      styleMask: [.borderless], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    let alert = NSAlert()
    alert.messageText = "probe"
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: parent) { Self.sheetResponse = $0 }
    Self.keptSheetParent = parent
    Self.keptAlert = alert
    XCTAssertTrue(wait { parent.attachedSheet != nil }, "前提: 本物のシートが付いた")
    print(
      "[probe] D attached=\(parent.attachedSheet != nil) parent.isVisible=\(parent.isVisible) "
        + "parent.frame=\(parent.frame) sheet.isVisible=\(parent.attachedSheet?.isVisible ?? false) "
        + "onDisplays=\(describe(windowsOnDisplays()))")
  }

  func testE_TheTestAfterALeftSheetStartsWithNoWindowOnADisplay() {
    let parent = Self.keptSheetParent
    let sheet = parent?.attachedSheet
    recordNoWindowOnADisplayAtStart("E", kept: [parent, sheet])
    print(
      "[probe] E sheetStillAttached=\(sheet != nil) response=\(String(describing: Self.sheetResponse?.rawValue))")
    XCTAssertNil(Self.sheetResponse, "確認: 隔離はシートに応答しない（完了ハンドラが走らない）")
  }

  // MARK: 前面化

  /// 1 件の中でアプリを前面にして、終わりまで前面のまま残す（テスト自身は戻さない。次の testG が見る）。
  func testF_ActivationLeftIsABreach() {
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
      "[probe] F isActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) "
        + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    XCTAssertTrue(active, "前提: CI の上でアプリが前面になった")
    window.orderOut(nil)
  }

  /// 前面化したテスト（testF）の次のテストで、ポリシーが戻っていて、アプリが前面でなくなる。
  func testG_TheTestAfterAnActivationEndsUpInactive() {
    let policy = NSApp.activationPolicy()
    let activeAtStart = NSApp.isActive
    let begin = Date()
    let left = wait(upTo: 10) { !NSApp.isActive }
    print(
      "[probe] G start policy=\(policy.rawValue) isActive=\(activeAtStart) "
        + "inactiveAfter=\(left ? String(format: "%.3f", Date().timeIntervalSince(begin)) : "never(10s)") "
        + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    XCTAssertEqual(policy, .prohibited, "確認: 違反の次のテストの始まりで、ポリシーが戻っている")
    XCTAssertTrue(left, "確認: 前面化したテストの後、アプリが前面でなくなる")
  }

  // MARK: 前面のまま始まったテストの終わり

  /// もう一度、アプリを前面にしたまま終わる。隔離が終わりに呼ぶ deactivate は、ウィンドウサーバーの出来事が処理されるまで
  /// 効かないので、次の testI は前面のまま始まる見込み。
  func testH_ActivationLeftAgainIsABreach() {
    DeactivateCalls.install()
    XCTAssertFalse(NSApp.isActive, "前提: 始まりで前面でない")
    expectBreach("アクティベーションポリシー")
    expectBreach("アプリが前面になった")
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    let active = wait { NSApp.isActive }
    print("[probe] H isActive=\(NSApp.isActive) deactivateCalls=\(DeactivateCalls.count)")
    XCTAssertTrue(active, "前提: CI の上でアプリが前面になった")
  }

  /// 前面のまま始まり、ランループを回さずに（前面のまま）終わる。始まりで前面なので、隔離はこのテストを前面で落とさないが、
  /// 終わりに deactivate を 1 回呼ぶはず（次の testJ が数える）。
  func testI_StartsActiveAndEndsActive() {
    let activeAtStart = NSApp.isActive
    Self.deactivateCallsAtStartOfI = DeactivateCalls.count
    print(
      "[probe] I start isActive=\(activeAtStart) policy=\(NSApp.activationPolicy().rawValue) "
        + "deactivateCalls=\(DeactivateCalls.count)")
    XCTAssertTrue(activeAtStart, "前提: 始まりで前面")
  }

  func testJ_TheEndOfATestThatStartedActiveCallsDeactivate() {
    let before = Self.deactivateCallsAtStartOfI ?? -1
    let delta = DeactivateCalls.count - before
    let begin = Date()
    let left = wait(upTo: 10) { !NSApp.isActive }
    print(
      "[probe] J deactivateCallsDuringEndOfI=\(delta) "
        + "inactiveAfter=\(left ? String(format: "%.3f", Date().timeIntervalSince(begin)) : "never(10s)")")
    XCTAssertEqual(delta, 1, "確認: 前面のまま始まったテストの終わりにも、deactivate が 1 回呼ばれる")
    XCTAssertTrue(left, "確認: その後、アプリが前面でなくなる")
  }

  // MARK: 片付け

  /// 残したシートを片付ける（診断の後片付け。隔離の確認ではない）。
  func testK_CleanUp() {
    // 片付けで窓が並び直したときは、隔離が記録する。診断は落とさない。
    expectBreach("ディスプレイの範囲", strict: false)
    if let parent = Self.keptSheetParent, let sheet = parent.attachedSheet {
      parent.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    }
    Self.keptSheetParent?.orderOut(nil)
    Self.keptSheetParent = nil
    Self.keptAlert = nil
    print("[probe] K done onDisplays=\(describe(windowsOnDisplays()))")
  }
}

/// `NSApplication.deactivate` が呼ばれた回数を数える（元の実装は呼ぶ）。CI の診断でだけ使う。
private enum DeactivateCalls {
  nonisolated(unsafe) static var count = 0
  nonisolated(unsafe) private static var installed = false

  static func install() {
    guard !installed else { return }
    installed = true
    let selector = #selector(NSApplication.deactivate)
    guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
    typealias Deactivate = @convention(c) (AnyObject, Selector) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Deactivate.self)
    let counting: @convention(block) (AnyObject) -> Void = { app in
      count += 1
      original(app, selector)
    }
    method_setImplementation(method, imp_implementationWithBlock(counting))
  }
}
