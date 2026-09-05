import SwiftUI

/// AppKit 側が所有する NSView（端末タブの器）をそのまま SwiftUI に配置する passthrough。
struct NSViewContainer: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
