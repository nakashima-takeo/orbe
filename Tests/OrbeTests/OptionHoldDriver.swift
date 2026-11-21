import AppKit

@testable import Orbe

/// 窓の ⌥ だけの長押しを、合成したイベントと差し替えた修飾の実状態で動かす。本物のキーボードには触れない。
final class OptionHoldDriver {
  private let wc: WindowController
  private var modifiers: NSEvent.ModifierFlags = []

  init(_ wc: WindowController) {
    self.wc = wc
    wc.optionHold.probe = OptionHoldMonitor.Probe(
      modifiers: { [unowned self] in modifiers }, mouseButtonDown: { false }, pointer: { .zero })
  }

  /// 修飾を `flags` にした flagsChanged を窓へ送る（実状態も同じにする）。
  func send(_ flags: NSEvent.ModifierFlags) {
    modifiers = flags
    let event = NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wc.window.windowNumber,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
    NSApp.sendEvent(event)
  }

  /// ⌥ だけを押し、成立するまで待つ。
  func hold() {
    send(.option)
    pump(upTo: 1, until: { wc.optionHold.isHolding })
  }

  /// キーボード以外の届いたイベントを配送しながら待つ（期限のタイマーを進める）。窓が key の間に本物のキーボードから
  /// 届いたイベントは配送しない——送った修飾とキーだけを判定に通すため。
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
