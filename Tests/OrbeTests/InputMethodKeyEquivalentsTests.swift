import AppKit
import XCTest

@testable import Orbe

/// 変換中の ⌘ 付きのキーは、窓の根でまず焦点の受け手の IME へ渡る。IME が使わなければ今と同じ順で流れ、使えばそこで
/// 止まる。口を持たない受け手と変換中でない受け手では、根は今のまま。壊れると変換中の ⌘ キーでアプリのコマンドが IME より
/// 先に走る、または端末の ⌘T・⌘V が変換中に効かなくなる。
@MainActor
final class InputMethodKeyEquivalentsTests: OrbeTestCase {
  /// 口を持つ受け手の偽物。IME が使ったかを決めておき、問われた回数を数える。
  private final class Receiver: NSView, InputMethodKeyEquivalents {
    var imeUses = false
    private(set) var offered = 0
    override var acceptsFirstResponder: Bool { true }
    func offerKeyEquivalentToInputMethod(_ event: NSEvent) -> Bool {
      offered += 1
      return imeUses
    }
  }

  /// 偽の入力の仕組み。出来事を受けたときに IME がすることを決めておく。
  private final class FakeInputContext: NSTextInputContext {
    var onEvent: ((NSTextInputClient) -> Void)?
    private(set) var events = 0
    override func handleEvent(_ event: NSEvent) -> Bool {
      events += 1
      onEvent?(client)
      return true
    }
  }

  /// 窓の根と、根が走らせた window コマンドの記録。
  private struct Root {
    let view: ChromeHostingView
    let window: NSWindow
    let handled: () -> [WindowCommand]
  }

  private func root(firstResponder receiver: NSView) -> Root {
    let model = AppShellModel(statusModel: StatusRowModel(), content: receiver)
    let view = ChromeHostingView(
      rootView: AppShell(
        model: model, translucency: ChromeTranslucency(), agentIconResolver: AgentIconResolver(),
        fontResolver: ChromeFontResolver(), localization: LocalizationStore(language: .en)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    window.makeFirstResponder(receiver)
    var handled: [WindowCommand] = []
    view.onWindowCommand = {
      handled.append($0)
      return true
    }
    addTeardownBlock { @MainActor in window.contentView = nil }
    return Root(view: view, window: window, handled: { handled })
  }

  func testTheRootOffersCommandKeysToTheInputMethodFirst() {
    let receiver = Receiver()
    let root = root(firstResponder: receiver)
    let (view, handled) = (root.view, root.handled)
    XCTAssertTrue(root.window.firstResponder === receiver, "前提: 受け手が焦点")
    XCTAssertTrue(view.performKeyEquivalent(with: .key("t")))
    XCTAssertEqual(handled(), [.newTab], "IME が使わなければ今の順（⌘T は新しいタブ）")
    XCTAssertEqual(receiver.offered, 1)
    receiver.imeUses = true
    XCTAssertTrue(view.performKeyEquivalent(with: .key("t")), "IME が使ったキーは根で止まる")
    XCTAssertEqual(handled(), [.newTab], "アプリのコマンドは走らない")
    _ = view.performKeyEquivalent(with: .key("t", [.control]))
    XCTAssertEqual(receiver.offered, 2, "⌘ の付かないキーは渡さない")
  }

  func testReceiversWithoutThePortKeepTheCurrentOrder() {
    let root = root(firstResponder: NSTextView())
    let (view, handled) = (root.view, root.handled)
    XCTAssertTrue(view.performKeyEquivalent(with: .key("t")))
    XCTAssertEqual(handled(), [.newTab])
  }

  /// 端末の面は窓の根の口に答える——変換中に IME が使った ⌘ キーは根で止まり、使わなければ今の順（⌘T は新しいタブ）で流れる。
  func testTheRootOffersTheTerminalsCommandKeysToItsInputMethod() {
    let terminal = SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), cwd: "/tmp")
    let context = FakeInputContext(client: terminal)
    terminal.textInputContext = context
    let root = root(firstResponder: terminal)
    XCTAssertTrue(root.window.firstResponder === terminal, "前提: 端末が焦点")
    terminal.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    context.onEvent = {
      $0.setMarkedText(
        "かn", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    XCTAssertTrue(root.view.performKeyEquivalent(with: .key("t")))
    XCTAssertEqual(root.handled(), [], "IME が使った ⌘T では新しいタブを開かない")
    context.onEvent = { $0.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
    XCTAssertTrue(root.view.performKeyEquivalent(with: .key("t")))
    XCTAssertEqual(root.handled(), [.newTab], "IME が使わなければ今の順")
    XCTAssertEqual(context.events, 2)
  }

  /// 端末の面: 変換中でなければ IME へ渡さない。変換中は渡し、渡している間にキー割り当てのコマンドが届けば IME は使わな
  /// かった（端末の今の順へ戻る）。IME が未確定を置き換えるだけなら使った。
  func testTheTerminalOffersOnlyWhileComposing() {
    let terminal = SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), cwd: "/tmp")
    let context = FakeInputContext(client: terminal)
    terminal.textInputContext = context
    XCTAssertFalse(terminal.offerKeyEquivalentToInputMethod(.key("v")))
    XCTAssertEqual(context.events, 0, "変換中でなければ渡さない")
    terminal.markedText = NSMutableAttributedString(string: "か")
    context.onEvent = { $0.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
    XCTAssertFalse(terminal.offerKeyEquivalentToInputMethod(.key("v")), "コマンドが届いた＝使わなかった")
    context.onEvent = {
      $0.setMarkedText(
        "かn", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    XCTAssertTrue(terminal.offerKeyEquivalentToInputMethod(.key("v")), "IME が使った")
    XCTAssertEqual(terminal.markedText.string, "かn")
  }
}
