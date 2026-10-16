import AppKit
import SwiftUI

/// 押すと OS のメニューを自分の下に出す透明な当たり（SwiftUI の Menu は見本の姿に描けないため、見た目は SwiftUI、押下と
/// メニューは AppKit）。
struct ScmMenuAnchor: NSViewRepresentable {
  let help: String
  let menu: () -> NSMenu

  func makeNSView(context: Context) -> AnchorView { AnchorView() }

  func updateNSView(_ view: AnchorView, context: Context) {
    view.menuMaker = menu
    view.toolTip = help
  }

  final class AnchorView: NSView {
    var menuMaker: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) {
      guard let menu = menuMaker?() else { return }
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 2 : -2), in: self)
    }
  }
}

/// 閉包で動く OS のメニュー。
enum ScmMenu {
  struct Item {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    init(_ title: String, _ isEnabled: Bool, _ action: @escaping () -> Void) {
      self.title = title
      self.isEnabled = isEnabled
      self.action = action
    }
  }

  /// nil は区切り線。
  static func make(_ items: [Item?]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for item in items {
      guard let item else {
        menu.addItem(.separator())
        continue
      }
      let entry = ActionItem(title: item.title, action: item.action)
      entry.isEnabled = item.isEnabled
      menu.addItem(entry)
    }
    return menu
  }

  private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
      handler = action
      super.init(title: title, action: #selector(fire), keyEquivalent: "")
      target = self
    }
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
  }
}
