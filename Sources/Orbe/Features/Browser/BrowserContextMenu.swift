import Foundation

/// サイドバーのタブ・自由スペース右クリックメニューの純粋な項目構成と実行ディスパッチ。
/// SwiftUI 側では標準の `.contextMenu` へそのまま投影し、テストではウィンドウを出さず純粋検証する。
enum BrowserContextMenu {
  enum TabAction: Equatable {
    case pin
    case favorite
    case unpinToToday
    case moveToPinned
    case moveToToday
    case close
  }

  enum TabMenuEntry: Equatable, Identifiable {
    case action(TabAction, L10nKey)
    case separator

    var id: String {
      switch self {
      case .action(let action, _): "\(action)"
      case .separator: "separator"
      }
    }
  }

  enum FreeSpaceAction: Equatable {
    case edit
    case delete
  }

  struct FreeSpaceMenuEntry: Equatable, Identifiable {
    let action: FreeSpaceAction
    let titleKey: L10nKey

    var id: String { "\(action)" }
  }

  static func tabItems(for tab: BrowserTab, in spaceKind: BrowserSpaceKind) -> [TabMenuEntry] {
    var entries: [TabMenuEntry] = []
    switch tab.section {
    case .today:
      entries.append(.action(.pin, .browserMenuPin))
      if spaceKind == .free {
        entries.append(.action(.favorite, .browserMenuAddFavorite))
      }
    case .pinned:
      if spaceKind == .free {
        entries.append(.action(.favorite, .browserMenuAddFavorite))
      }
      entries.append(.action(.unpinToToday, .browserMenuUnpin))
    case .favorite:
      entries.append(.action(.moveToPinned, .browserMenuMoveToPinned))
      entries.append(.action(.moveToToday, .browserMenuMoveToToday))
    }
    entries.append(.separator)
    entries.append(.action(.close, .browserMenuCloseTab))
    return entries
  }

  @MainActor
  static func execute(_ action: TabAction, tabId: UUID, on session: BrowserSession) {
    switch action {
    case .pin, .moveToPinned:
      _ = session.moveTab(tabId, to: .pinned)
    case .favorite:
      _ = session.moveTab(tabId, to: .favorite)
    case .unpinToToday, .moveToToday:
      _ = session.moveTab(tabId, to: .today)
    case .close:
      _ = session.closeTab(tabId, recordClosed: true)
    }
  }

  static func freeSpaceItems() -> [FreeSpaceMenuEntry] {
    [
      FreeSpaceMenuEntry(action: .edit, titleKey: .browserMenuEditSpace),
      FreeSpaceMenuEntry(action: .delete, titleKey: .browserMenuDeleteSpace),
    ]
  }
}
