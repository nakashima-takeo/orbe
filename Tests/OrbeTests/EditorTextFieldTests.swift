import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 命令でフォーカスを入れる 1 行の入力欄（`EditorTextField`）——フォーカスの要求は、欄が窓に載った時点か、要求が来た時点で
/// 欄自身が当てて消す。断られても要求は消え、後でフォーカスを奪わない。取り消し・やり直しで変わった欄の字は使う側の値にも
/// 写り、使う側が中身を差し替えた後は、前の取り消しの履歴が残らない。
///
/// 壊れると何が起きるか。⌘⇧F で検索の列が出ても、入力欄に焦点が入らず、打った字が本文に入る。焦点の切り替えを断られた
/// 要求が残り、後で欄が出し直されたときに、打っている本文から焦点を奪う。⌘Z で欄の字だけが戻り、検索語や絞り込みの字と
/// 食い違う。外から検索語を入れ直した後の ⌘Z で例外が上がる・検索語が壊れる。
@MainActor
final class EditorTextFieldTests: OrbeTestCase {
  /// 使う側の値（欄の字）と、欄への焦点の要求と、欄が要求を当てた回数。
  @Observable final class Probe {
    var text = ""
    var wantsFocus = false
    var applied = 0
  }

  private struct Content: View {
    let probe: Probe

    var body: some View {
      EditorTextField(
        text: probe.text, placeholder: "", font: .systemFont(ofSize: 12), placeholderColor: .gray,
        wantsFocus: probe.wantsFocus,
        requestDidApply: {
          probe.wantsFocus = false
          probe.applied += 1
        },
        onTextChange: { probe.text = $0 })
    }
  }

  /// 焦点を手放すかどうかを決められる、欄の隣の受け手。
  private final class Holder: NSView {
    var lets = true
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool { lets }
  }

  private struct Hosted {
    let window: NSWindow
    let host: NSHostingView<Content>
    let holder: Holder

    /// 焦点が欄にあるか（first responder が欄の field editor）。
    @MainActor var fieldHasFocus: Bool {
      (window.firstResponder as? NSView)?.isDescendant(of: host) == true
    }
  }

  /// 欄の host と受け手を窓に載せる。焦点は受け手が持つ。
  private func hosted(_ probe: Probe) -> Hosted {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless],
      backing: .buffered, defer: false)
    holdUntilTestEnds(window)
    let root = NSView(frame: window.contentLayoutRect)
    window.contentView = root
    let holder = Holder(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
    root.addSubview(holder)
    let host = NSHostingView(rootView: Content(probe: probe))
    host.frame = NSRect(x: 0, y: 30, width: 300, height: 30)
    root.addSubview(host)
    window.makeFirstResponder(holder)
    addTeardownBlock { @MainActor in window.contentView = nil }
    return Hosted(window: window, host: host, holder: holder)
  }

  /// main のランループの「後で走らせる仕事」（欄が要求を当てる経路）に目印を積み、目印が走るまで待つ。この関数から戻ったとき、
  /// この関数を呼ぶ前に積まれていた仕事は走り終えている。
  private func runScheduledWork() {
    final class Mark: @unchecked Sendable { var reached = false }
    let mark = Mark()
    RunLoop.main.perform { mark.reached = true }
    pumpMain(until: { mark.reached }, "ランループの目印")
  }

  /// 欄が窓に無い間に出た要求は、欄が窓に載った時点で当たって消える。
  func testARequestMadeWhileTheFieldIsOutOfTheWindowIsAppliedWhenItArrives() throws {
    let probe = Probe()
    let hosted = hosted(probe)
    hosted.host.layoutSubtreeIfNeeded()
    hosted.host.removeFromSuperview()
    probe.wantsFocus = true
    hosted.host.layoutSubtreeIfNeeded()
    runScheduledWork()
    XCTAssertEqual(probe.applied, 0, "前提: 窓に無い間は当てない")

    hosted.window.contentView?.addSubview(hosted.host)
    runScheduledWork()
    XCTAssertTrue(
      hosted.fieldHasFocus,
      "欄が窓に載った時点で焦点が入る（目印を待つだけで焦点が入る。焦点が入らなくなれば、"
        + "testADeclinedRequestIsDroppedAndDoesNotTakeTheFocusLater が「焦点を奪わない」を確かめる時点は、効果が届く前になる）")
    XCTAssertEqual(probe.applied, 1, "要求は消える")
  }

  /// 焦点の切り替えが断られても、要求は消え、その後に欄が窓に載り直しても焦点を奪わない。
  func testADeclinedRequestIsDroppedAndDoesNotTakeTheFocusLater() throws {
    let probe = Probe()
    let hosted = hosted(probe)
    hosted.host.layoutSubtreeIfNeeded()
    hosted.holder.lets = false
    probe.wantsFocus = true
    pumpMain(until: { probe.applied == 1 }, "要求は当たって消える")
    XCTAssertTrue(hosted.window.firstResponder === hosted.holder, "断られれば焦点は元の所")

    hosted.holder.lets = true
    hosted.host.removeFromSuperview()
    hosted.window.contentView?.addSubview(hosted.host)
    // 載った時点で当てる経路の仕事を走らせ終えてから見る（対は、窓に無い間に出た要求が載った時点で当たるテスト）。
    runScheduledWork()
    XCTAssertTrue(hosted.window.firstResponder === hosted.holder, "後で焦点を奪わない")
  }

  /// 欄に焦点を入れ、field editor を返す。
  private func focusField(_ hosted: Hosted, _ probe: Probe) throws -> NSTextView {
    probe.wantsFocus = true
    pumpMain(until: { hosted.fieldHasFocus }, "欄に焦点")
    return try XCTUnwrap(hosted.window.firstResponder as? NSTextView)
  }

  /// 取り消し・やり直しで欄の字が変われば、使う側の値も同じ字になる。
  func testUndoAndRedoReachTheCallersValue() throws {
    let probe = Probe()
    let hosted = hosted(probe)
    hosted.host.layoutSubtreeIfNeeded()
    let editor = try focusField(hosted, probe)
    editor.insertText("ab", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(probe.text, "ab", "前提: 打った字が届く")
    let undo = try XCTUnwrap(editor.undoManager)
    // 打鍵の取り消しのまとまりは、ランループの 1 周の終わりで閉じる。
    pumpMainOnce()

    undo.undo()
    XCTAssertEqual(editor.string, "", "前提: 欄の字が戻る")
    XCTAssertEqual(probe.text, "", "取り消しで使う側の値も戻る")
    undo.redo()
    XCTAssertEqual(probe.text, "ab", "やり直しで使う側の値も進む")
  }

  /// 使う側が中身を差し替えた後は、差し替える前の取り消しの履歴が残らない（⌘Z で古い範囲の操作が新しい中身に働かない）。
  func testReplacingTheTextFromOutsideDiscardsTheUndoHistory() throws {
    let probe = Probe()
    let hosted = hosted(probe)
    hosted.host.layoutSubtreeIfNeeded()
    let editor = try focusField(hosted, probe)
    editor.insertText("alpha beta", replacementRange: NSRange(location: 0, length: 0))
    pumpMainOnce()
    XCTAssertTrue(editor.undoManager?.canUndo == true, "前提: 打鍵を取り消せる")
    hosted.window.makeFirstResponder(hosted.holder)

    probe.text = "x"
    hosted.host.layoutSubtreeIfNeeded()
    let back = try focusField(hosted, probe)

    XCTAssertEqual(back.string, "x", "前提: 差し替えた中身")
    XCTAssertFalse(back.undoManager?.canUndo == true, "差し替える前の履歴は残らない")
  }
}
