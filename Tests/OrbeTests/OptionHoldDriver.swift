import AppKit

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
  func hold() {
    send(.option)
    pump(upTo: 1, until: { monitor.isHolding })
  }

  /// キーボード以外の届いたイベントを配送しながら待つ（期限のタイマーを進める）。本物のキーボードから届いたイベントは
  /// 配送しない——送った修飾とキーだけを判定に通すため。
  func pump(upTo seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    let mask = NSEvent.EventTypeMask.any.subtracting([.keyDown, .keyUp, .flagsChanged])
    while Date() < end, !done() {
      guard
        let event = NSApp.nextEvent(
          matching: mask, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true)
      else { continue }
      NSApp.sendEvent(event)
    }
  }
}
