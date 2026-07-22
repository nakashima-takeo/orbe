import SwiftUI

/// facade 所有の NSView（行領域 scroll・コミット欄）をそのまま SwiftUI に配置する passthrough。
struct NSViewContainer: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
