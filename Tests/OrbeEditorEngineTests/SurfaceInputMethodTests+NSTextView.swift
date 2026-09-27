import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 窓を出さない NSTextView と同じ IME の呼び出し列を流して突き合わせる——undo のまとまり。壊れると IME の取り消しや
/// 選択の上の変換の後で、⌘Z の戻り方が macOS の他のアプリと食い違う。
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
  fileprivate static func span(_ location: Int, _ length: Int) -> NSRange {
    NSRange(location: location, length: length)
  }
}
