import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 足場が預けたウィンドウ（`holdUntilTestEnds`・`hostEditor`）は、戻り値を捨てても、テスト 1 件の終わりまで生きていて、
/// その後に解放される。
///
/// 壊れると何が起きるか。預けたウィンドウがテストの途中で解放されると、載せたビューがウィンドウを失い、ウィンドウに載って
/// いる間だけ動く部品（first responder・ポインタの位置・エディターの面のファイルの監視）が、テストがウィンドウを保持する
/// コードを書かない限り、黙って別の動きになる。手放されないと、テストのたびにウィンドウと、載っているエディターの面（ファイル
/// の監視と git を握る）が溜まり、後のテストの裏で動き続ける。
@MainActor
final class WindowHoldingTests: OrbeTestCase {
  private struct Released {
    weak var window: NSWindow?
  }

  private nonisolated(unsafe) static var released: [Released] = []

  /// 解放は、テスト 1 件ごとの終わり（`invokeTest` の最後）に起きる。クラスで 1 回の `tearDown` は、全テストが終わった後に
  /// 走る。
  nonisolated override static func tearDown() {
    XCTAssertFalse(released.isEmpty, "前提: 預けたウィンドウを記録した")
    XCTAssertTrue(released.allSatisfy { $0.window == nil }, "預けたウィンドウはテストの後に解放される")
    released.removeAll()
    super.tearDown()
  }

  func testAHeldWindowLivesUntilTheTeardownBlocks() {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let window = holdUntilTestEnds(
      OrbeWindowFake(
        contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false))
    window.contentView = view
    Self.released.append(Released(window: window))
    addTeardownBlock { @MainActor in XCTAssertNotNil(view.window, "テスト本文の後もウィンドウに載っている") }
  }

  func testAnEditorWindowLivesUntilTheTeardownBlocks() {
    let tab = TerminalTab.alone(
      cwd: TestScratch.caseDir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    hostEditor(tab, width: 600)
    let view = tab.group.view
    Self.released.append(Released(window: view.window))
    addTeardownBlock { @MainActor in XCTAssertNotNil(view.window, "テスト本文の後もウィンドウに載っている") }
  }
}
