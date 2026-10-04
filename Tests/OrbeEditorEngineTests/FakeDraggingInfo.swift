import AppKit

/// ドラッグの偽物。落とす位置（窓の座標）・板・送り手・送り手が許す操作をテストが決めて、受け手の口を直に呼ぶ。
@MainActor
final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
  var draggingLocation: NSPoint
  let draggingPasteboard: NSPasteboard
  let draggingSource: Any?
  let draggingSourceOperationMask: NSDragOperation
  var draggingFormation = NSDraggingFormation.default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1

  init(
    at location: NSPoint, pasteboard: NSPasteboard, source: Any? = nil,
    operations: NSDragOperation = [.copy, .move]
  ) {
    draggingLocation = location
    draggingPasteboard = pasteboard
    draggingSource = source
    draggingSourceOperationMask = operations
  }

  var draggingDestinationWindow: NSWindow? { nil }
  var draggedImageLocation: NSPoint { draggingLocation }
  var draggedImage: NSImage? { nil }
  var draggingSequenceNumber: Int { 1 }
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }

  func slideDraggedImage(to screenPoint: NSPoint) {}
  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
    classes classArray: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
}
