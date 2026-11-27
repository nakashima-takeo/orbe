import Foundation

/// `BrowserStore` のプロファイル・スペース・シート比率・削除キュー操作。
extension BrowserStore {
  // MARK: - Profiles

  func createProfile(
    name: String, color: BrowserProfileColor, mcpAllowed: Bool, now: Date = Date()
  ) -> BrowserStoreCommitResult<BrowserProfile> {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .failed }
    let created = BrowserProfile(
      id: UUID(), name: trimmed, color: color, mcpAllowed: mcpAllowed,
      position: profiles.count, createdAt: BrowserPersistence.storedInstant(now))
    return commit { db, draft in
      try db?.insertProfile(created)
      draft.profiles.append(created)
      return created
    }
  }

  func updateProfile(
    _ id: UUID, name: String, color: BrowserProfileColor, mcpAllowed: Bool
  ) -> BrowserStoreCommitResult<BrowserProfile> {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else {
      return .failed
    }
    var updated = profiles[index]
    updated.name = trimmed
    updated.color = color
    updated.mcpAllowed = mcpAllowed
    return commit { db, draft in
      try db?.updateProfile(updated)
      draft.profiles[index] = updated
      return updated
    }
  }

  /// プロファイルを削除し、参照スペースを `fallbackProfileId` へ付け替え、OS ストア削除キューへ積む。
  func deleteProfile(
    _ id: UUID, reassigningTo fallbackProfileId: UUID, now: Date = Date()
  ) -> BrowserStoreCommitResult<Void> {
    guard profiles.count > 1,
      id != fallbackProfileId,
      profiles.contains(where: { $0.id == id }),
      profiles.contains(where: { $0.id == fallbackProfileId })
    else { return .failed }
    let removal = BrowserPendingStoreRemoval(
      storeId: id, queuedAt: BrowserPersistence.storedInstant(now))
    return commit { db, draft in
      try db?.reassignSpaces(fromProfile: id, toProfile: fallbackProfileId)
      try db?.deleteProfile(id)
      for i in draft.spaces.indices where draft.spaces[i].profileId == id {
        draft.spaces[i].profileId = fallbackProfileId
      }
      draft.profiles.removeAll { $0.id == id }
      for i in draft.profiles.indices where draft.profiles[i].position != i {
        draft.profiles[i].position = i
        try db?.updateProfilePosition(draft.profiles[i].id, position: i)
      }
      try db?.insertPendingStoreRemoval(removal)
      draft.pendingStoreRemovals.removeAll { $0.storeId == id }
      draft.pendingStoreRemovals.append(removal)
    }
  }

  func removePendingStoreRemoval(_ storeId: UUID) -> BrowserStoreCommitResult<Void> {
    guard pendingStoreRemovals.contains(where: { $0.storeId == storeId }) else {
      return noopResult(())
    }
    return commit { db, draft in
      try db?.deletePendingStoreRemoval(storeId)
      draft.pendingStoreRemovals.removeAll { $0.storeId == storeId }
    }
  }

  // MARK: - Spaces & Workspace 連動

  /// 現在の workspace を同期し、該当ローカルスペースが無ければ 1 トランザクションで遅延作成する。
  func setCurrentWorkspace(_ workspaceId: UUID, now: Date = Date())
    -> BrowserStoreCommitResult<BrowserSpace>
  {
    if let existing = localSpace(for: workspaceId) {
      currentWorkspaceId = workspaceId
      return noopResult(existing)
    }
    guard let profileId = defaultLocalProfileId else { return .failed }
    let created = BrowserSpace(
      id: UUID(), kind: .local, workspaceId: workspaceId, name: "", icon: .local,
      profileId: profileId, position: 0, createdAt: BrowserPersistence.storedInstant(now))
    let result = commit { db, draft in
      try db?.insertSpace(created)
      draft.spaces.append(created)
      return created
    }
    if result.didSucceed {
      currentWorkspaceId = workspaceId
    }
    return result
  }

  func selectSpace(_ selection: BrowserActiveSpaceSelection) -> BrowserStoreCommitResult<Void> {
    if case .free(let id) = selection,
      !spaces.contains(where: { $0.id == id && $0.kind == .free })
    {
      return .failed
    }
    guard activeSpaceSelection != selection else { return noopResult(()) }
    return commit { db, draft in
      try db?.updateActiveSpace(selection)
      draft.activeSpaceSelection = selection
    }
  }

  func createFreeSpace(
    name: String, icon: BrowserSpaceIcon, profileId: UUID, now: Date = Date()
  ) -> BrowserStoreCommitResult<BrowserSpace> {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, icon != .local, profiles.contains(where: { $0.id == profileId }) else {
      return .failed
    }
    let created = BrowserSpace(
      id: UUID(), kind: .free, workspaceId: nil, name: trimmed, icon: icon,
      profileId: profileId, position: freeSpaces.count,
      createdAt: BrowserPersistence.storedInstant(now))
    return commit { db, draft in
      try db?.insertSpace(created)
      draft.spaces.append(created)
      return created
    }
  }

  func updateFreeSpace(_ id: UUID, name: String, icon: BrowserSpaceIcon)
    -> BrowserStoreCommitResult<BrowserSpace>
  {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, icon != .local,
      let index = spaces.firstIndex(where: { $0.id == id && $0.kind == .free })
    else { return .failed }
    var updated = spaces[index]
    updated.name = trimmed
    updated.icon = icon
    return commit { db, draft in
      try db?.updateSpace(updated)
      draft.spaces[index] = updated
      return updated
    }
  }

  func setSpaceProfile(_ spaceId: UUID, profileId: UUID) -> BrowserStoreCommitResult<BrowserSpace> {
    guard let index = spaces.firstIndex(where: { $0.id == spaceId }),
      profiles.contains(where: { $0.id == profileId })
    else { return .failed }
    if spaces[index].profileId == profileId {
      return noopResult(spaces[index])
    }
    var updated = spaces[index]
    updated.profileId = profileId
    return commit { db, draft in
      try db?.updateSpaceProfile(spaceId, profileId: profileId)
      draft.spaces[index] = updated
      return updated
    }
  }

  /// 自由スペースと配下タブ・閉じたタブ履歴を削除し、削除されたタブ ID 一覧を返す。
  func deleteFreeSpace(_ id: UUID) -> BrowserStoreCommitResult<[UUID]> {
    guard spaces.contains(where: { $0.id == id && $0.kind == .free }) else { return .failed }
    let removedTabIds = tabs.filter { $0.spaceId == id }.map(\.id)
    let fallbackSelection: BrowserActiveSpaceSelection? =
      if activeSpaceSelection == .free(id) {
        freeSpaces.first(where: { $0.id != id }).map { .free($0.id) } ?? .local
      } else {
        nil
      }
    return commit { db, draft in
      if let fallbackSelection {
        try db?.updateActiveSpace(fallbackSelection)
        draft.activeSpaceSelection = fallbackSelection
      }
      try db?.deleteSpace(id)
      draft.spaces.removeAll { $0.id == id }
      draft.tabs.removeAll { $0.spaceId == id }
      draft.activeTabBySpace.removeValue(forKey: id)
      draft.closedTabs.removeAll { $0.originalSpaceId == id }
      let remainingFree = draft.spaces.filter { $0.kind == .free }.sorted(by: Self.spaceOrder)
      for (pos, space) in remainingFree.enumerated() where space.position != pos {
        if let idx = draft.spaces.firstIndex(where: { $0.id == space.id }) {
          draft.spaces[idx].position = pos
        }
        try db?.updateSpacePosition(space.id, position: pos)
      }
      return removedTabIds
    }
  }

  /// 削除された workspace に紐づくローカルスペースと配下タブ・閉じたタブ履歴を除去し、削除タブ ID 一覧を返す。
  func removeLocalSpace(for workspaceId: UUID) -> BrowserStoreCommitResult<[UUID]> {
    guard let space = localSpace(for: workspaceId) else { return noopResult([]) }
    let removedTabIds = tabs.filter { $0.spaceId == space.id }.map(\.id)
    let result = commit { db, draft in
      try db?.deleteSpace(space.id)
      draft.spaces.removeAll { $0.id == space.id }
      draft.tabs.removeAll { $0.spaceId == space.id }
      draft.activeTabBySpace.removeValue(forKey: space.id)
      draft.closedTabs.removeAll { $0.originalSpaceId == space.id }
      return removedTabIds
    }
    if result.didSucceed, currentWorkspaceId == workspaceId {
      currentWorkspaceId = nil
    }
    return result
  }

  // MARK: - Sheet ratio

  func setSheetRatio(_ ratio: Double) -> BrowserStoreCommitResult<Double> {
    let bps = BrowserPersistence.ratioBps(from: ratio)
    let normalized = BrowserPersistence.ratio(fromBps: bps)
    guard bps != sheetRatioBps else { return noopResult(normalized) }
    return commit { db, draft in
      try db?.updateSheetRatioBps(bps)
      draft.sheetRatioBps = bps
      return normalized
    }
  }
}
