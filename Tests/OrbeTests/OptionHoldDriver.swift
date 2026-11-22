import AppKit
import OrbeTestSupport

@testable import Orbe

/// 窓の ⌥ だけの長押しを、合成したイベントと差し替えた修飾の実状態で動かす。本物のキーボードには触れない。
final class OptionHoldDriver {
  private let monitor: OptionHoldMonitor
  private let window: NSWindow
  /// OS が返す修飾の実状態の代わり。`send` は知らせと一緒に変え、直接書けば知らせの無いまま変わる（取りこぼし）。
  var actualModifiers: NSEvent.ModifierFlags = []

  init(_ monitor: OptionHoldMonitor, in window: NSWindow) {
    self.monitor = monitor
    self.window = window
    monitor.probe = OptionHoldMonitor.Probe(
      modifiers: { [unowned self] in actualModifiers }, mouseButtonDown: { false },
      pointer: { .zero })
  }

  convenience init(_ wc: WindowController) {
    self.init(wc.optionHold, in: wc.window)
  }

  /// 修飾を `flags` にした flagsChanged を窓へ送る（実状態も同じにする）。
  func send(_ flags: NSEvent.ModifierFlags) {
    actualModifiers = flags
    let event = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
    NSApp.sendEvent(event)
  }

  /// ⌥ だけを押し、成立するまで待つ。
  func hold(file: StaticString = #filePath, line: UInt = #line) {
    send(.option)
    pumpMain(until: { monitor.isHolding }, timeout: 1, "⌥ の長押しが成立する", file: file, line: line)
  }
}
