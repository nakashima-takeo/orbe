import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 窓を出さない NSTextView と同じ IME の呼び出し列を流して突き合わせる——undo のまとまりと、範囲を指した確定の後の選択。
/// 壊れると IME の取り消しや長押しのアクセントの後で、⌘Z の戻り方やキャレットの行き先が macOS の他のアプリと食い違う。
extension SurfaceInputMethodTests {
  /// undo のまとまりは NSTextView と同じ——IME 自身の取り消しで本文が元に戻れば何も載らず、打鍵のまとまりも切れない（後の
  /// 打鍵は前の打鍵と 1 回で戻る）。確定は前後の打鍵とまとまる。選択の上の変換は選択の上の打鍵と同じく、選択の前の打鍵とは
  /// 別で、確定でも取り消しでも後の打鍵とまとまる。
  func testUndoAroundTheInputMethodMatchesNSTextView() throws {
    let ab: [NativeStep] = [.type("a"), .type("b")]
    let all = NSRange.span(0, 2)
    let cases: [UndoCase] = [
      UndoCase("取り消し → 打鍵", ab + [.ime(.mark("か")), .ime(.mark("")), .type("c")], ["abc", ""]),
      UndoCase("確定 → 打鍵", ab + [.ime(.mark("か")), .ime(.insert("か")), .type("c")], ["abかc", ""]),
      UndoCase("取り消しだけ", ab + [.ime(.mark("か")), .ime(.mark(""))], ["ab", ""]),
      UndoCase(
        "選択の上で取り消し → 打鍵",
        ab + [.select(all), .ime(.mark("か")), .ime(.mark("")), .type("c")], ["c", "ab", ""]
      ),
      UndoCase(
        "選択の上で確定 → 打鍵",
        ab + [.select(all), .ime(.mark("か")), .ime(.insert("か")), .type("c")],
        ["かc", "ab", ""]
      ),
      UndoCase("選択の上で打鍵 → 打鍵", ab + [.select(all), .type("x"), .type("c")], ["xc", "ab", ""]),
      UndoCase(
        "選択の上で確定",
        ab + [.select(.span(1, 1)), .ime(.mark("か")), .ime(.insert("か"))],
        ["aか", "ab", ""]
      ),
      UndoCase(
        "選択の上で取り消し", ab + [.select(all), .ime(.mark("か")), .ime(.mark(""))], ["", "ab", ""]),
    ]
    for item in cases {
      XCTAssertEqual(nativeUndoTrail(item.steps), item.trail, "NSTextView: \(item.label)")
      let opened = try open("")
      _ = host(opened)
      fakeInputMethod(opened)
      for step in item.steps {
        switch step {
        case .type(let string): type(opened, string)
        case .select(let range): opened.surface.selectedRange = range
        case .ime(let call): replay([call], on: opened)
        }
      }
      let undo = try XCTUnwrap(opened.surface.textView.undoManager)
      var trail = [text(opened.document)]
      while undo.canUndo {
        undo.undo()
        trail.append(text(opened.document))
      }
      XCTAssertEqual(trail, item.trail, item.label)
    }
  }

  /// 範囲を指した確定の後の選択は NSTextView と同じ——置き換えが選択より前なら選択をずらし、後ろなら保ち、重なれば入れた
  /// 文字の終わりのキャレット。本文に収まらない範囲は、指していないものとして無視する（打鍵と同じ）。
  func testReplacingInsertTextSelectsLikeNSTextView() throws {
    let cases: [(selection: NSRange, calls: [IMECall])] = [
      (.caret(5), [.insert("Q", replacement: .span(1, 2))]),
      (.caret(5), [.insert("QQQQ", replacement: .span(1, 2))]),
      (.caret(5), [.insert("Q", replacement: .span(3, 2))]),
      (.caret(5), [.insert("Q", replacement: .span(5, 2))]),
      (.caret(5), [.insert("Q", replacement: .span(4, 3))]),
      (.caret(5), [.insert("Q", replacement: .span(4, 1))]),
      (.caret(5), [.insert("Q", replacement: .span(8, 2))]),
      (.caret(5), [.insert("Q", replacement: .span(5, 0))]),
      (.caret(5), [.insert("Q", replacement: .span(2, 0))]),
      (.caret(5), [.insert("Q", replacement: .span(8, 0))]),
      (.caret(0), [.insert("Q", replacement: .span(0, 3))]),
      (.span(3, 4), [.insert("Q", replacement: .span(1, 3))]),
      (.span(3, 4), [.insert("Q", replacement: .span(4, 1))]),
      (.span(3, 4), [.insert("QQ", replacement: .span(6, 3))]),
      (.span(3, 4), [.insert("Q", replacement: .span(2, 6))]),
      (.span(3, 4), [.insert("Q", replacement: .span(7, 1))]),
      (.span(3, 4), [.insert("Q", replacement: .span(1, 2))]),
      (.span(3, 4), [.insert("QQ", replacement: .span(2, 1))]),
      (.span(3, 4), [.insert("QQ", replacement: .span(3, 4))]),
      (.span(3, 4), [.insert("Q", replacement: .span(3, 0))]),
      (.span(3, 4), [.insert("Q", replacement: .span(5, 0))]),
      (.span(3, 4), [.insert("Q", replacement: .span(7, 0))]),
      (.caret(5), [.insert("Q", replacement: .span(12, 0))]),
      (.caret(5), [.insert("Q", replacement: .span(8, 5))]),
      (.caret(5), [.insert("Q", replacement: .span(10, 1))]),
      (.caret(5), [.insert("Q", replacement: .span(10, 0))]),
      (.caret(5), [.insert("Q", replacement: .span(9, 1))]),
    ]
    for (selection, calls) in cases { try assertMatchesNSTextView(selection, calls) }
  }

  /// 変換中に範囲を指した確定も NSTextView と同じ——選択の規則を IME の選択（未確定の中）に当て、未確定の文字は確定として
  /// 残る。本文（未確定を含む）に収まらない範囲は、指していないものとして未確定を置き換える。
  func testReplacingInsertTextWhileComposingSelectsLikeNSTextView() throws {
    let cases: [(selection: NSRange, calls: [IMECall])] = [
      (
        NSRange.caret(5),
        [.mark("かな", selected: .span(0, 2)), .insert("Q", replacement: .span(0, 1))]
      ),
      (
        NSRange.caret(5),
        [.mark("かな", selected: .span(1, 0)), .insert("Q", replacement: .span(0, 1))]
      ),
      (.caret(5), [.mark("かな"), .insert("Q", replacement: .span(8, 1))]),
      (
        NSRange.caret(5),
        [.mark("かな", selected: .span(0, 2)), .insert("Q", replacement: .span(4, 2))]
      ),
      (
        NSRange.caret(5),
        [.mark("かな", selected: .span(1, 0)), .insert("Q", replacement: .span(6, 1))]
      ),
      (.caret(5), [.mark("かな"), .insert("Q", replacement: .span(7, 0))]),
      (.caret(5), [.mark("かな", selected: .span(0, 2)), .insert("仮名")]),
      (.caret(5), [.mark("かな"), .insert("Q", replacement: .span(13, 0))]),
      (.caret(5), [.mark("かな"), .insert("Q", replacement: .span(11, 2))]),
      (.caret(5), [.mark("かな"), .insert("Q", replacement: .span(11, 1))]),
      (.caret(5), [.mark("かな"), .insert("Q", replacement: .span(12, 0))]),
      (.caret(5), [.mark("かな", replacement: .span(9, 2)), .insert("Q")]),
      (.caret(5), [.mark("かな"), .mark("き", replacement: .span(12, 1))]),
    ]
    for (selection, calls) in cases { try assertMatchesNSTextView(selection, calls) }
  }

  /// `0123456789` に `selection` を置いて `calls` を流した本文・選択・未確定が、NSTextView と同じ。
  private func assertMatchesNSTextView(
    _ selection: NSRange, _ calls: [IMECall], file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let base = "0123456789"
    let label = "選択 \(selection) \(calls)"
    let (view, window) = nativeTextView(base)
    defer { window.contentView = nil }
    view.setSelectedRange(selection)
    let opened = try open(base)
    _ = host(opened)
    fakeInputMethod(opened)
    opened.surface.selectedRange = selection
    for call in calls {
      call.send(to: view)
      replay([call], on: opened, file: file, line: line)
    }
    let client = opened.surface.textView
    XCTAssertEqual(text(opened.document), view.string, label, file: file, line: line)
    XCTAssertEqual(client.selectedRange(), view.selectedRange(), label, file: file, line: line)
    XCTAssertEqual(client.hasMarkedText(), view.hasMarkedText(), label, file: file, line: line)
    if view.hasMarkedText() {
      XCTAssertEqual(client.markedRange(), view.markedRange(), label, file: file, line: line)
    }
  }

  /// 窓を出さない NSTextView（窓は前に出さず、焦点だけを与える。undo は出来事ごとの組）。
  private func nativeTextView(_ string: String) -> (NSTextView, NSWindow) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.allowsUndo = true
    view.string = string
    window.contentView = view
    window.makeFirstResponder(view)
    return (view, window)
  }

  /// NSTextView に手順を 1 つずつ別の出来事として流し（手順の間に run loop を回して undo の組を閉じる——実際の打鍵と同じ
  /// 組み方）、undo を尽くすまでの本文の列を返す。
  private func nativeUndoTrail(_ steps: [NativeStep]) -> [String] {
    let (view, window) = nativeTextView("")
    defer { window.contentView = nil }
    for step in steps {
      switch step {
      case .type(let string): view.insertText(string, replacementRange: IMECall.notFound)
      case .select(let range): view.setSelectedRange(range)
      case .ime(let call): call.send(to: view)
      }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard let undo = view.undoManager else { return [] }
    var trail = [view.string]
    while undo.canUndo {
      undo.undo()
      trail.append(view.string)
    }
    return trail
  }
}

/// NSTextView と突き合わせる手順 1 つ。
private enum NativeStep {
  case type(String)
  case select(NSRange)
  case ime(IMECall)
}

/// NSTextView と突き合わせる undo の列 1 つ——手順と、undo を尽くすまでの本文の列。
private struct UndoCase {
  let label: String
  let steps: [NativeStep]
  let trail: [String]

  init(_ label: String, _ steps: [NativeStep], _ trail: [String]) {
    self.label = label
    self.steps = steps
    self.trail = trail
  }
}

extension NSRange {
  fileprivate static func caret(_ offset: Int) -> NSRange { NSRange(location: offset, length: 0) }
  fileprivate static func span(_ location: Int, _ length: Int) -> NSRange {
    NSRange(location: location, length: length)
  }
}
