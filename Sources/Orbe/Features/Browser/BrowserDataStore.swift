import Foundation
import WebKit

/// プロファイル別 `WKWebsiteDataStore` の唯一の生成・削除口。
/// 動的隔離判定（`StateDir.isIsolated || !store.available`）が真の間は
/// `.default()`・`WKWebsiteDataStore(forIdentifier:)`・`remove(forIdentifier:)` を一切評価せず、
/// プロファイル UUID ごとに独立した `.nonPersistent()` をキャッシュ共有する。
@MainActor
final class BrowserDataStoreRegistry {
  typealias PersistentStoreRemover = @MainActor (UUID, @escaping (Bool) -> Void) -> Void

  private let isIsolatedProvider: () -> Bool
  private var nonPersistentStores: [UUID: WKWebsiteDataStore] = [:]
  private let remover: PersistentStoreRemover

  var isIsolated: Bool { isIsolatedProvider() }

  init(
    isIsolated: @escaping () -> Bool = { StateDir.isIsolated },
    remover: @escaping PersistentStoreRemover = BrowserDataStoreRegistry.defaultRemover
  ) {
    isIsolatedProvider = isIsolated
    self.remover = remover
  }

  func store(for profileId: UUID) -> WKWebsiteDataStore {
    if isIsolated {
      if let existing = nonPersistentStores[profileId] {
        return existing
      }
      let created = WKWebsiteDataStore.nonPersistent()
      nonPersistentStores[profileId] = created
      return created
    }
    return WKWebsiteDataStore(forIdentifier: profileId)
  }

  func releaseCache(for profileId: UUID) {
    nonPersistentStores.removeValue(forKey: profileId)
  }

  func removePersistentStore(for profileId: UUID, completion: @escaping (Bool) -> Void) {
    guard !isIsolated else {
      completion(false)
      return
    }
    remover(profileId, completion)
  }

  static func defaultRemover(_ profileId: UUID, completion: @escaping (Bool) -> Void) {
    WKWebsiteDataStore.remove(forIdentifier: profileId) { error in
      DispatchQueue.main.async {
        if let error {
          NSLog("[browser] failed to remove WKWebsiteDataStore \(profileId): \(error)")
          completion(false)
        } else {
          completion(true)
        }
      }
    }
  }
}
