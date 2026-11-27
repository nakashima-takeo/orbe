import Foundation

/// プロファイルの識別色トークン。
enum BrowserProfileColor: String, CaseIterable, Equatable, Sendable {
  case green
  case blue
  case amber
  case purple
  case pink
  case teal
}

/// ブラウザのプロファイル。Cookie・`localStorage`・MCP 読み取り可否の単位。
/// `id` は `WKWebsiteDataStore(forIdentifier:)` の識別子を兼ねるランダム UUID。
struct BrowserProfile: Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var color: BrowserProfileColor
  var mcpAllowed: Bool
  var position: Int
  let createdAt: Date
}

/// ブラウザスペースの種別。
enum BrowserSpaceKind: String, Equatable, Sendable {
  case free
  case local
}

/// ブラウザスペースのアイコン種別。ローカルスペースは `.local` 固定。
enum BrowserSpaceIcon: String, CaseIterable, Equatable, Sendable {
  case person
  case briefcase
  case search
  case globe
  case code
  case star
  case local
}

/// ブラウザのスペース。全 workspace 共通の自由スペースと、workspace ごとに 1 対 1 対応するローカルスペース。
struct BrowserSpace: Identifiable, Equatable, Sendable {
  let id: UUID
  let kind: BrowserSpaceKind
  let workspaceId: UUID?
  var name: String
  var icon: BrowserSpaceIcon
  var profileId: UUID
  var position: Int
  let createdAt: Date
}

/// タブの配置区分。ローカルスペースでは `.favorite` を持たない。
enum BrowserTabSection: String, CaseIterable, Equatable, Sendable {
  case favorite
  case pinned
  case today

  var sortOrder: Int {
    switch self {
    case .favorite: 0
    case .pinned: 1
    case .today: 2
    }
  }
}

/// ブラウザのタブ 1 枚。
struct BrowserTab: Identifiable, Equatable, Sendable {
  let id: UUID
  let spaceId: UUID
  var section: BrowserTabSection
  var position: Int
  var url: URL?
  var title: String
  let createdAt: Date
  var lastActiveAt: Date
}

/// 手動閉鎖・手動整理で積まれる閉じたタブ履歴 1 件。必ず元のスペースへ復元する。
struct BrowserClosedTab: Identifiable, Equatable, Sendable {
  let id: Int64
  let url: URL
  let title: String
  let originalSpaceId: UUID
  let closedAt: Date
}

/// 現在アクティブなスペース枠の論理表現。
/// `.local` は現在アクティブな workspace のローカルスペースを指す。
enum BrowserActiveSpaceSelection: Equatable, Hashable, Sendable {
  case free(UUID)
  case local
}

/// プロファイル削除後に OS 側の永続 `WKWebsiteDataStore` 削除を待つキュー項目。
struct BrowserPendingStoreRemoval: Equatable, Sendable {
  let storeId: UUID
  let queuedAt: Date
}

/// `BrowserStore` の単一書き込み経路の結果 3 態。
enum BrowserStoreCommitResult<T> {
  case persisted(T)
  case inMemory(T)
  case failed

  var value: T? {
    switch self {
    case .persisted(let value), .inMemory(let value): value
    case .failed: nil
    }
  }

  var didSucceed: Bool {
    if case .failed = self { return false }
    return true
  }

  var didPersist: Bool {
    if case .persisted = self { return true }
    return false
  }
}

extension BrowserStoreCommitResult: Equatable where T: Equatable {}

/// `BrowserStore` が保持する永続対象メモリスナップショット。
struct BrowserMemory: Equatable {
  var profiles: [BrowserProfile]
  var spaces: [BrowserSpace]
  var tabs: [BrowserTab]
  var activeTabBySpace: [UUID: UUID]
  var closedTabs: [BrowserClosedTab]
  var activeSpaceSelection: BrowserActiveSpaceSelection
  var sheetRatioBps: Int
  var pendingStoreRemovals: [BrowserPendingStoreRemoval]

  static let defaultFreeSpaceSpecs: [(icon: BrowserSpaceIcon, key: L10nKey)] = [
    (.person, .browserDefaultSpacePersonal),
    (.briefcase, .browserDefaultSpaceWork),
    (.search, .browserDefaultSpaceResearch),
  ]

  /// 初回起動時および DB 利用不可時の既定構成を組む（プロファイル 2 種・自由スペース 3 種・初期選択 `.local`）。
  static func makeDefaultSeed(language: Language, now: Date) -> BrowserMemory {
    let createdAt = BrowserPersistence.storedInstant(now)
    let personal = BrowserProfile(
      id: UUID(), name: "personal", color: .green, mcpAllowed: false, position: 0,
      createdAt: createdAt)
    let work = BrowserProfile(
      id: UUID(), name: "work", color: .blue, mcpAllowed: true, position: 1,
      createdAt: createdAt)
    let profileIds = [personal.id, work.id, work.id]
    let freeSpaces = zip(Self.defaultFreeSpaceSpecs, profileIds).enumerated().map { idx, pair in
      BrowserSpace(
        id: UUID(), kind: .free, workspaceId: nil,
        name: L10n.string(pair.0.key, language), icon: pair.0.icon,
        profileId: pair.1, position: idx, createdAt: createdAt)
    }
    return BrowserMemory(
      profiles: [personal, work],
      spaces: freeSpaces,
      tabs: [],
      activeTabBySpace: [:],
      closedTabs: [],
      activeSpaceSelection: .local,
      sheetRatioBps: BrowserPersistence.defaultSheetRatioBps,
      pendingStoreRemovals: [])
  }
}
