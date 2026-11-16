import AppKit

/// ポインタの位置を差し替えられる窓。本物のポインタを動かさず、窓の key の状態も変えない。`answersAsKey` なら、key で
/// ないまま key と答える——窓が key のときだけポインタの位置を読んでホバーを引き直す view に、テストでも引き直させるため。
public final class PointerWindow: NSWindow {
  public var pointer = NSPoint.zero
  public var answersAsKey = false

  override public var mouseLocationOutsideOfEventStream: NSPoint { pointer }
  override public var isKeyWindow: Bool { answersAsKey || super.isKeyWindow }
}
