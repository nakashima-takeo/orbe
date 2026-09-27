import AppKit
import XCTest

@testable import Orbe

/// IME が keyDown の外で確定した文字（変換中の ⌘ キーを IME へ渡している間の確定・音声入力・文字ビューア）は、打った文字
/// として PTY へ届く。壊れると確定した文字が bracketed paste に包まれ、端末のアプリが貼り付けとして扱う（貼り付けの強調・
/// 貼り付け専用の処理）。
extension SurfaceKeyInputTests {
  /// 偽の入力の仕組み。出来事を受けたときに IME がすることを決めておく。
  private final class FakeInputContext: NSTextInputContext {
    var onEvent: ((NSTextInputClient) -> Void)?
    override func handleEvent(_ event: NSEvent) -> Bool {
      onEvent?(client)
      return true
    }
  }

  /// keyDown の外の確定は、bracketed paste が有効でも包まれず、kitty keyboard protocol でも文字のまま届く。
  @MainActor
  func testCommitsOutsideKeyDownArriveAsTypedText() throws {
    for mode in [TtyDumpTab.Mode.paste, .kitty] {
      let dump = try dump(mode)
      dump.tab.surface.insertText("漢字", replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertEqual(dump.next(), TtyDumpTab.hex("漢字"), "\(mode)")
    }
  }

  /// 変換中の ⌘V を IME へ渡している間に、IME が先に確定してからキー割り当てのコマンドを返しても（IME は使わなかった）、
  /// 確定した文字は打った文字として届く。
  @MainActor
  func testACommitWhileOfferingACommandKeyArrivesAsTypedText() throws {
    let dump = try dump(.paste)
    let surface = dump.tab.surface
    let context = FakeInputContext(client: surface)
    surface.textInputContext = context
    surface.markedText = NSMutableAttributedString(string: "かん")
    context.onEvent = {
      $0.insertText("感", replacementRange: NSRange(location: NSNotFound, length: 0))
      $0.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }
    XCTAssertFalse(surface.offerKeyEquivalentToInputMethod(.key("v")), "コマンドが届いた＝使わなかった")
    XCTAssertFalse(surface.hasMarkedText())
    XCTAssertEqual(dump.next(), TtyDumpTab.hex("感"))
  }
}
