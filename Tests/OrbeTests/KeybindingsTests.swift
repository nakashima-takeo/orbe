import AppKit
import XCTest

@testable import Orbe

/// chrome が先取りするキー（surface へ転送しない操作）を守る。壊れると、ヘルプに載っているのに
/// 押しても効かないショートカットや、ヘルプに無いまま端末から奪われるキーが生まれる。
final class KeybindingsTests: OrbeTestCase {
  /// 矢印キーは specialKey の unicode（charactersIgnoringModifiers）から判定されるため、その文字で生成する。
  private func arrow(_ k: NSEvent.SpecialKey, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent
  {
    .key(String(UnicodeScalar(k.rawValue)!), flags)
  }

  /// ヘルプの行のうち chrome ではなくメニュー・端末・修飾の素タップが担うもの。
  /// chrome はこれらを奪ってはいけない（奪えば ⌘C のコピーや ⌘Q の終了が効かなくなる）。
  private let handledOutsideChrome: Set = ["⌘Q", "⌘C", "⌘V", "⌘⌘"]

  /// ヘルプが案内する ⌘ ショートカットと、chrome が実際に先取りする操作は一致する。
  /// ヘルプ（人が読む掲載）と Keybindings（キーの振り分け）は別々に書かれた 2 つの正本で、
  /// どちらか片方だけを変えると落ちる。
  func testHelpListsExactlyTheOperationsChromeTakes() {
    var advertised: Set<ChromeAction> = []
    for row in HelpCatalog.all.flatMap(\.rows) {
      let action = Keybindings.chromeAction(for: event(for: row))
      if handledOutsideChrome.contains(row.key) {
        XCTAssertNil(action, "\(row.key) は chrome 以外が担うので先取りしない")
      } else if let action {
        advertised.insert(action)
      } else {
        XCTFail("ヘルプの \(row.key) を押しても chrome が受けない")
      }
    }

    XCTAssertEqual(
      takenFromKeyboard(), advertised, "chrome が先取りするのに、ヘルプに載っていない操作がある")
  }

  /// 端末やエディターに届くべきキーは奪わない。⌘ の無いキー、Opt / Ctrl を併せたキーは奪わない
  /// （surface 側の super+alt 系の keybind を遮蔽しない）。
  func testKeysOwnedByTheFaceAreNotTaken() {
    XCTAssertNil(Keybindings.chromeAction(for: .key("t", [])))
    XCTAssertNil(Keybindings.chromeAction(for: .key("t", [.control])))
    // ⌘← / ⌘→ は行頭・行末移動。
    XCTAssertNil(Keybindings.chromeAction(for: arrow(.rightArrow)))
    XCTAssertNil(Keybindings.chromeAction(for: arrow(.leftArrow)))
    XCTAssertNil(Keybindings.chromeAction(for: arrow(.upArrow, [.command, .shift])))
    XCTAssertNil(Keybindings.chromeAction(for: arrow(.downArrow, [.command, .shift])))
    // 全選択・切り取り・分割など、mac と端末の慣習のキー。
    for chars in ["a", "d"] {
      XCTAssertNil(Keybindings.chromeAction(for: .key(chars)), "⌘\(chars)")
    }
    XCTAssertNil(Keybindings.chromeAction(for: .key("D", [.command, .shift])))
    XCTAssertNil(Keybindings.chromeAction(for: .key("H", [.command, .shift])))
    // Opt / Ctrl 併用。⌘⌥H は macOS の「ほかを隠す」。
    XCTAssertNil(Keybindings.chromeAction(for: .key("h", [.command, .option])))
    XCTAssertNil(Keybindings.chromeAction(for: .key("e", [.command, .option])))
    XCTAssertNil(Keybindings.chromeAction(for: .key(",", [.command, .option])))
    XCTAssertNil(Keybindings.chromeAction(for: .key("S", [.command, .shift, .option])))
    XCTAssertNil(Keybindings.chromeAction(for: .key("f", [.command, .control])))
  }

  /// ChromeHostingView は window レベルでタブ非依存 window コマンド（availableWithoutTabs）だけを
  /// 横取りし、surface 操作系（⌘W closeTab）や content 依存コマンド（⌘R renameTab）は
  /// 素通しする（0タブでもタブ非依存キーが届き、他は surface 経由 no-op のまま、の切り分けの機構部分）。
  /// libghostty 非依存（surface を作らず AppShell の SwiftUI ルートだけ構築する）。
  func testChromeHostingViewInterceptsTabIndependentCommandsOnly() {
    let model = AppShellModel(statusModel: StatusRowModel(), content: NSView())
    let view = ChromeHostingView(
      rootView: AppShell(
        model: model, translucency: ChromeTranslucency(), agentIconResolver: AgentIconResolver(),
        fontResolver: ChromeFontResolver(), localization: LocalizationStore(language: .en)))
    var handled: [WindowCommand] = []
    view.onWindowCommand = { command in
      handled.append(command)
      return true
    }

    XCTAssertTrue(
      view.performKeyEquivalent(with: .key("t")), "⌘T（worktree パレット）は横取りして処理する")
    XCTAssertEqual(handled, [.showWorktreePalette], "⌘T でハンドラが .showWorktreePalette で1回呼ばれる")

    _ = view.performKeyEquivalent(with: .key("w"))
    XCTAssertEqual(
      handled, [.showWorktreePalette], "⌘W（closeTab・surface 操作系）は横取りせずハンドラを呼ばない")

    _ = view.performKeyEquivalent(with: .key("r"))
    XCTAssertEqual(
      handled, [.showWorktreePalette], "⌘R（renameTab・content 依存）は横取りせず subtree へ流す")
  }

  // MARK: - 補助

  /// US 配列で ⇧ を併せたときの文字（記号キー）。
  private static let shiftedSymbols: [String: String] = [
    "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*",
    "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"",
    ",": "<", ".": ">", "/": "?",
  ]

  /// 物理キー 1 つ（`HelpCatalog.keyboard` の id）を ⌘（＋⇧）で押した出来事。文字を持たないキーは nil。
  private func event(key id: String, shift: Bool) -> [NSEvent] {
    let flags: NSEvent.ModifierFlags = shift ? [.command, .shift] : .command
    switch id {
    case "left": return [arrow(.leftArrow, flags)]
    case "right": return [arrow(.rightArrow, flags)]
    case "ud": return [arrow(.upArrow, flags), arrow(.downArrow, flags)]
    default:
      guard id.count == 1 else { return [] }
      guard shift else { return [.key(id, flags)] }
      return [.key(Self.shiftedSymbols[id] ?? id.uppercased(), flags)]
    }
  }

  /// ヘルプの 1 行を押した出来事（⌘↑ / ⌘↓ は同じ物理キー `ud` を共有するので表示キーで分ける）。
  private func event(for row: HelpCatalog.Row) -> NSEvent {
    switch row.key {
    case "⌘↑": return arrow(.upArrow)
    case "⌘↓": return arrow(.downArrow)
    case "⌘⌘": return .key("", .command)
    default:
      let main = row.combo.first { !HelpCatalog.modifierKeys.contains($0) } ?? ""
      return event(key: main, shift: row.combo.contains("shift")).first ?? .key("", .command)
    }
  }

  /// キーボードの全キーを ⌘ と ⌘⇧ で押して、chrome が先取りした操作の集合。
  private func takenFromKeyboard() -> Set<ChromeAction> {
    let keys = HelpCatalog.keyboard.flatMap { $0 }.map(\.id)
    let events = keys.flatMap { event(key: $0, shift: false) + event(key: $0, shift: true) }
    return Set(events.compactMap { Keybindings.chromeAction(for: $0) })
  }
}
