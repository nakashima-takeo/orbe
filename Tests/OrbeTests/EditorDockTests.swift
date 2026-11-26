import AppKit
import OrbeEditorCore
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 上のバーの右下の置き場——ポップアップの器（`EditorPopup`）を本物の面に載せたときの開閉・閉じ方・フォーカス・キー・押下と、
/// 置き場の並び（`EditorDockStack`）・失敗の札（`EditorFailureCard`）。載せる側は偽物で、受けた口を記録する。
///
/// 壊れると何が起きるか。開いても入力欄にフォーカスが入らず、打鍵が本文へ入る。閉じた後に打鍵がどこにも届かない・コミットの
/// 後に変更の列へ戻らない。端末や左の列へフォーカスを移しても開いたまま残り、移した先のフォーカスを奪い返す。閉じる直前の
/// 知らせが届かず、書きかけと変換中の字が消える。⌘↵ が中身に届かずコミットできない。一覧とポップアップが重なって開く。
/// 置き場の何も無い所で本体の右上が押せない。窓が低いと失敗の札がポップアップの下に隠れる。札の × を押しても消えない。
@MainActor
final class EditorDockTests: OrbeTestCase {
  /// フォーカスを受け取れる view。
  final class Focusable: NSView {
    override var acceptsFirstResponder: Bool { true }
  }

  /// 偽物の載せる側。中身は、フォーカスを受け取れる欄 2 つ。開いた知らせで `field` へフォーカスを入れる。
  @MainActor final class Owner: EditorPopupOwner {
    let field = Focusable()
    let other = Focusable()
    /// 扱う ⌘ つきのキー。
    var handledKeys: Set<String> = ["\r", "b"]
    /// 開いた知らせを受けた時点で、中身が窓に載っていたか。
    private(set) var openedInWindow: [Bool] = []
    /// 閉じる直前の知らせのきっかけと、その時点で中身が窓に載っていたか。
    private(set) var closings: [(dismissal: EditorDismissal, inWindow: Bool)] = []
    private(set) var keys: [String] = []
    /// 地の下に、地の外へ並べるメニュー（右寄せ・幅 `menuWidth`）を出すか。
    var showsMenu = false
    static let menuWidth: CGFloat = 250
    /// 中身を組んだ回数。
    private(set) var contentCalls = 0
    /// 窓に載った中身の印（中身が作り直されるたびに、新しい印が増える）。
    private(set) var contentStamps: [UUID] = []

    func popupContent() -> AnyView {
      contentCalls += 1
      return AnyView(
        VStack(alignment: .trailing, spacing: 6) {
          Stamp { [weak self] in self?.contentStamps.append($0) }
          EditorPopupGround {
            HStack {
              Embedded(view: self.field).frame(width: 200, height: 26)
              Embedded(view: self.other).frame(width: 100, height: 26)
            }
            .padding(8)
          }
          if self.showsMenu {
            Color.gray.frame(width: Self.menuWidth, height: 80).editorDockItem()
          }
        })
    }

    func popupDidOpen() {
      openedInWindow.append(field.window != nil)
      field.window?.makeFirstResponder(field)
    }

    func popupWillClose(_ dismissal: EditorDismissal) {
      closings.append((dismissal, field.window != nil))
    }

    func popupKeyEquivalent(_ event: NSEvent) -> Bool {
      let key = event.charactersIgnoringModifiers ?? ""
      keys.append(key)
      return handledKeys.contains(key)
    }

    var dismissals: [EditorDismissal] { closings.map(\.dismissal) }
  }

  /// 閉包から書き込む記録。
  final class Record<Value> {
    var value: Value

    init(_ value: Value) { self.value = value }
  }

  struct Hosted {
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    let document: EditorDocument
    @MainActor var popup: EditorPopup { pane.popup }
  }

  /// 文書を 1 つ開いた面（Files の画面）を窓に載せ、本文にフォーカスを置く。
  func host() throws -> Hosted {
    let tab = TerminalTab.alone(
      cwd: TestScratch.caseDir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900, height: 600)
    let document = try tab.group.editor.open(try caseFile("a.txt", "a"), as: .pinned)
    window.makeFirstResponder(document.surface.responder)
    return Hosted(tab: tab, pane: tab.group.view.editor, window: window, document: document)
  }

  /// ポップアップを開き、置き場の host が並んでいる物の枠を受け取るまで待つ。
  private func openAndSettle(_ hosted: Hosted, _ owner: Owner) {
    hosted.popup.toggle(owner)
    pumpMain(until: { !hosted.pane.dockHost.itemFrames.isEmpty }, "置き場が中身の枠を受け取る")
  }

  // MARK: - 開閉とフォーカス

  /// 右端のボタン（開閉の切り替え）で開くと、中身が窓に載った後に開いた知らせが届き、中身の欄にフォーカスが入る。もう一度
  /// 押すと、中身がまだ窓に居るうちに閉じる直前の知らせが届き、フォーカスは本体へ戻る。
  func testTheButtonOpensThePopupWithTheFocusInItsContentAndClosesIt() throws {
    let hosted = try host()
    let owner = Owner()

    hosted.popup.toggle(owner)
    XCTAssertTrue(hosted.popup.isOpen)
    XCTAssertEqual(owner.openedInWindow, [true], "開いた知らせの時点で中身は窓に載っている")
    XCTAssertTrue(hosted.window.firstResponder === owner.field, "中身の欄にフォーカス")

    hosted.popup.toggle(owner)
    XCTAssertFalse(hosted.popup.isOpen)
    XCTAssertEqual(owner.dismissals, [.toggle])
    XCTAssertEqual(owner.closings.map(\.inWindow), [true], "閉じる直前の知らせの時点で中身は窓に居る")
    XCTAssertTrue(
      hosted.window.firstResponder === hosted.document.surface.responder, "フォーカスは本体へ戻る")
  }

  /// 開く前のフォーカスが左の列の変更の列に在れば、閉じたら変更の列へ戻る。閉じるまでに左の列を閉じて一覧が無くなって
  /// いれば、本体へ戻る。
  func testClosingReturnsTheFocusToTheListItWasOpenedFrom() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = hostEditor(tab, width: 900, height: 600)
    let list = pane.scmList.list
    pane.switchScreen(.changes)
    pumpMain(until: { window.firstResponder === list }, "前提: 変更の列にフォーカス")
    let owner = Owner()

    pane.popup.toggle(owner)
    XCTAssertTrue(window.firstResponder === owner.field, "前提: 中身の欄にフォーカス")
    pane.popup.close(.escape)
    pumpMain(until: { window.firstResponder === list }, "変更の列へ戻る")

    pane.popup.toggle(owner)
    pane.toggleSidebar()
    pane.popup.close(.escape)
    XCTAssertTrue(window.firstResponder === pane.focusTarget, "一覧が無くなっていれば本体へ戻る")
  }

  /// フォーカスが置き場の中で移っても閉じない。置き場の外へ移れば閉じ、フォーカスは移った先に残る。フォーカスが窓へ落ちれば
  /// （フォーカスを持っていた view が外れた）閉じて、開く前の場所（本体）へ戻る。
  func testTheFocusLeavingTheDockClosesThePopupWithoutMovingTheFocus() throws {
    let hosted = try host()
    let owner = Owner()
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    hosted.tab.group.view.addSubview(outsider)
    hosted.popup.toggle(owner)

    hosted.window.makeFirstResponder(owner.other)
    nextTurn()
    XCTAssertTrue(hosted.popup.isOpen, "置き場の中で移っても開いたまま")

    XCTAssertTrue(hosted.window.makeFirstResponder(outsider))
    nextTurn()
    XCTAssertFalse(hosted.popup.isOpen, "置き場の外へ移れば閉じる")
    XCTAssertEqual(owner.dismissals, [.focusLeft])
    let responder = try XCTUnwrap(hosted.window.firstResponder as? NSView)
    XCTAssertTrue(responder === outsider || responder.isDescendant(of: outsider), "移った先に残る")

    hosted.window.makeFirstResponder(hosted.document.surface.responder)
    hosted.popup.toggle(owner)
    hosted.window.makeFirstResponder(nil)
    nextTurn()
    XCTAssertFalse(hosted.popup.isOpen, "窓へ落ちれば閉じる")
    XCTAssertTrue(
      hosted.window.firstResponder === hosted.document.surface.responder, "開く前の場所へ戻る")
  }

  // MARK: - 閉じるきっかけ

  /// 画面を切り替える・根が変わる（cd）・面が隠れる（⌘E）・面が窓から外れると閉じ、どれも、中身がまだ窓に居るうちに
  /// 閉じる直前の知らせが届く。
  func testSwitchingScreensChangingTheRootOrHidingTheFaceClosesThePopup() throws {
    let hosted = try host()
    let owner = Owner()
    let other = TestScratch.caseDir.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

    hosted.popup.toggle(owner)
    hosted.pane.switchScreen(.changes)
    pumpMain(until: { !hosted.popup.isOpen }, "画面を切り替えると閉じる")

    hosted.popup.toggle(owner)
    hosted.tab.group.rekey(GitWorktreeRoot.root(of: other.path))
    pumpMain(until: { !hosted.popup.isOpen }, "cd で閉じる")

    hosted.popup.toggle(owner)
    hosted.tab.group.view.show(.terminal, animated: false)
    XCTAssertFalse(hosted.popup.isOpen, "面が隠れると閉じる")

    hosted.tab.group.view.show(.editor, animated: false)
    hosted.popup.toggle(owner)
    hosted.window.contentView = nil
    XCTAssertFalse(hosted.popup.isOpen, "面が窓から外れると閉じる")

    XCTAssertEqual(owner.dismissals, [.itemGone, .itemGone, .faceHidden, .faceHidden])
    XCTAssertEqual(
      owner.closings.map(\.inWindow), [true, true, true, true], "どの知らせの時点でも、中身は窓に居る")
  }

  /// 右端のボタンが消えたら、そのボタンの枠の上の押下でも閉じる。画面を替えて、現れたボタンの知らせが、消えたボタンの知らせより
  /// 先に届いても、現れたボタンの上の押下では閉じない。
  func testAPressWhereAGoneButtonWasClosesThePopup() throws {
    let hosted = try host()
    let pane = hosted.pane
    let owner = Owner()
    let commit = (id: UUID(), frame: CGRect(x: 760, y: 5, width: 80, height: 26))
    let review = (id: UUID(), frame: CGRect(x: 660, y: 5, width: 80, height: 26))
    func press(_ frame: CGRect) {
      pane.pressWillArrive(
        .mouse(
          .leftMouseDown, at: pane.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil),
          in: hosted.window))
    }
    pane.shell.actionButtonFrameDidChange(commit.id, commit.frame)
    pane.shell.actionButtonFrameDidChange(review.id, review.frame)
    pane.shell.actionButtonFrameDidChange(commit.id, nil)

    hosted.popup.toggle(owner)
    press(review.frame)
    XCTAssertTrue(hosted.popup.isOpen, "現れたボタンの上の押下では閉じない")
    press(commit.frame)
    XCTAssertFalse(hosted.popup.isOpen, "消えたボタンの枠の上の押下では閉じる")
    XCTAssertEqual(owner.dismissals, [.outsidePress])
  }

  /// 置き場の外の押下は閉じて、フォーカスを開く前の場所（本体）へ戻す。置き場に並んでいる物と右端の主な操作のボタンの上の
  /// 押下、⌥ で透かしている間の押下では閉じない。
  func testAPressOutsideClosesUnlessItIsOnTheDockOrTheButtonOrWhilePeeking() throws {
    let hosted = try host()
    let pane = hosted.pane
    let owner = Owner()
    let button = CGRect(x: 760, y: 5, width: 80, height: 26)
    pane.shell.actionButtonFrameDidChange(UUID(), button)
    openAndSettle(hosted, owner)
    func press(_ point: NSPoint) {
      pane.pressWillArrive(.mouse(.leftMouseDown, at: point, in: hosted.window))
    }
    let item = try XCTUnwrap(pane.dockHost.itemFrames.first)

    press(pane.dockHost.convert(NSPoint(x: item.midX, y: item.midY), to: nil))
    XCTAssertTrue(hosted.popup.isOpen, "ポップアップの上の押下では閉じない")
    press(pane.convert(NSPoint(x: button.midX, y: button.midY), to: nil))
    XCTAssertTrue(hosted.popup.isOpen, "右端のボタンの上の押下では閉じない（ボタンの働きが閉じる）")

    let outside = pane.convert(NSPoint(x: 20, y: pane.bounds.midY), to: nil)
    pane.isPeeking = true
    press(outside)
    XCTAssertTrue(hosted.popup.isOpen, "透かしている間は閉じない")
    pane.isPeeking = false
    press(outside)
    XCTAssertFalse(hosted.popup.isOpen)
    XCTAssertEqual(owner.dismissals, [.outsidePress])
    XCTAssertTrue(hosted.window.firstResponder === hosted.document.surface.responder)
  }

  // MARK: - キー・一覧の器・押下の素通し

  /// フォーカスが置き場の中にある間の ⌘ つきのキーは、面のキー（⌘B の左の列の開閉）より先に中身へ届き、中身が扱えば面の
  /// キーは働かない。
  func testCommandKeysInTheDockReachTheContentBeforeThePanesKeys() throws {
    let hosted = try host()
    let owner = Owner()
    hosted.popup.toggle(owner)

    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key("b")))
    XCTAssertEqual(owner.keys, ["b"])
    XCTAssertTrue(hosted.pane.sidebar.isOpen, "中身が扱ったキーで左の列は閉じない")
    XCTAssertTrue(hosted.popup.isOpen)
  }

  /// ポップアップを開いたまま一覧を開くと（中身が扱わない ⌘P）、ポップアップは閉じてフォーカスは一覧へ移る。一覧を開いた
  /// ままポップアップを開くと、一覧は閉じてフォーカスはポップアップの中身へ移る。
  func testThePopupAndTheItemListDoNotOpenTogether() throws {
    let hosted = try host()
    let pane = hosted.pane
    let owner = Owner()
    hosted.popup.toggle(owner)

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("p")))
    XCTAssertTrue(pane.itemList.isOpen)
    XCTAssertFalse(hosted.popup.isOpen, "一覧を開くとポップアップは閉じる")
    XCTAssertEqual(owner.dismissals, [.otherOpened])
    XCTAssertTrue(pane.focusIsInItemList, "フォーカスは一覧へ")

    hosted.popup.toggle(owner)
    XCTAssertFalse(pane.itemList.isOpen, "ポップアップを開くと一覧は閉じる")
    XCTAssertTrue(hosted.window.firstResponder === owner.field, "フォーカスはポップアップの中身へ")
  }

  /// 置き場の中でも、並んでいる物の無い所の押下は、置き場が無いときと同じ下の view へ届く。並んでいる物の上の押下は置き場が
  /// 受ける。
  func testAPressOnAnEmptyPartOfTheDockReachesTheViewBelow() throws {
    let hosted = try host()
    let pane = hosted.pane
    let empty = NSPoint(x: pane.dockRect.midX, y: pane.dockRect.midY)
    func hit(_ point: NSPoint) -> NSView? { pane.hitTest(pane.convert(point, to: pane.superview)) }
    let below = try XCTUnwrap(hit(empty))

    openAndSettle(hosted, Owner())
    let item = try XCTUnwrap(pane.dockHost.itemFrames.first)
    XCTAssertFalse(
      pane.convert(item, from: pane.dockHost).contains(empty), "前提: 確かめる点は中身の外")
    let onEmpty = try XCTUnwrap(hit(empty))
    XCTAssertFalse(onEmpty.isDescendant(of: pane.dockHost), "何も無い所は置き場が受けない")
    XCTAssertTrue(onEmpty === below, "置き場が無いときと同じ下の view へ")
    let onItem = try XCTUnwrap(
      hit(pane.convert(NSPoint(x: item.midX, y: item.midY), from: pane.dockHost)))
    XCTAssertTrue(onItem.isDescendant(of: pane.dockHost), "中身の上は置き場が受ける")
  }

  /// 中身が地の外に並べた物（メニュー）の横の空いた所の押下は、置き場を素通りして下の view へ届き、外の押下として
  /// ポップアップを閉じる。並べた物の上の押下は置き場が受け、閉じない。
  func testAPressBesideWhatTheContentPlacesOutsideItsGroundPassesThrough() throws {
    let hosted = try host()
    let pane = hosted.pane
    let owner = Owner()
    owner.showsMenu = true
    func hit(_ point: NSPoint) -> NSView? { pane.hitTest(pane.convert(point, to: pane.superview)) }
    func press(_ point: NSPoint) {
      pane.pressWillArrive(
        .mouse(.leftMouseDown, at: pane.convert(point, to: nil), in: hosted.window))
    }

    openAndSettle(hosted, owner)
    pumpMain(until: { pane.dockHost.itemFrames.count == 2 }, "前提: 地とメニューの枠")
    let frames = pane.dockHost.itemFrames.map { pane.convert($0, from: pane.dockHost) }
    let menu = try XCTUnwrap(frames.first { $0.width == Owner.menuWidth })
    let ground = try XCTUnwrap(frames.first { $0 != menu })
    let beside = NSPoint(x: menu.minX - 20, y: menu.midY)
    XCTAssertTrue(
      beside.x > ground.minX && beside.y > ground.maxY, "前提: 確かめる点はポップアップの幅の中で、地の下")
    let onMenu = try XCTUnwrap(hit(NSPoint(x: menu.midX, y: menu.midY)))
    XCTAssertTrue(onMenu.isDescendant(of: pane.dockHost), "メニューの上は置き場が受ける")
    press(NSPoint(x: menu.midX, y: menu.midY))
    XCTAssertTrue(hosted.popup.isOpen, "メニューの上の押下では閉じない")

    let besideHit = try XCTUnwrap(hit(beside))
    XCTAssertFalse(besideHit.isDescendant(of: pane.dockHost), "メニューの横は置き場が受けない")
    press(beside)
    XCTAssertFalse(hosted.popup.isOpen, "メニューの横の押下は外の押下として閉じる")
    XCTAssertEqual(owner.dismissals, [.outsidePress])
  }
}

/// 作られるたびに新しい印を持ち、窓に載ったときに知らせる。
private struct Stamp: View {
  let appeared: (UUID) -> Void
  @State private var stamp = UUID()

  var body: some View {
    Color.clear.frame(width: 0, height: 0).onAppear { appeared(stamp) }
  }
}

/// 渡した NSView をそのまま載せる。
private struct Embedded: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView { view }

  func updateNSView(_ view: NSView, context: Context) {}
}
