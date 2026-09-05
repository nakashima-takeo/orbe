import Foundation

/// 旧 workspaces.json（version 2 / 3）の読みと現行形式への平坦化移行。旧形式を知るのはこのファイルだけで、
/// 現行モデルからは `WorkspacePersistence.load()` の 1 箇所が呼ぶ。
///
/// 旧形式はタブが分割ツリー（`LegacySplitTree` 二分木）を持っていた。葉ごとに 1 タブへ展開する。
extension WorkspacePersistence {
  static func loadLegacy(_ data: Data) -> WorkspacesFile? {
    guard let file = try? JSONDecoder().decode(LegacyWorkspacesFile.self, from: data) else {
      return nil
    }
    return file.migrated()
  }
}

private struct LegacyWorkspacesFile: Decodable {
  var version: Int
  var activeWorkspace: Int
  var workspaces: [LegacyWorkspaceState]
  var windowSize: WindowSize?

  func migrated() -> WorkspacesFile {
    WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: activeWorkspace,
      workspaces: workspaces.map { $0.migrated() }, windowSize: windowSize)
  }
}

private struct LegacyWorkspaceState: Decodable {
  var name: String
  var rootPath: String
  var activeTab: Int
  var tabs: [LegacyTabState]
  var lastUsedAt: Date?
  var settingsOverride: SettingsLayer?

  enum CodingKeys: String, CodingKey {
    case name, rootPath, activeTab, tabs, lastUsedAt, settingsOverride
  }

  /// settingsOverride は新形式（canonical key・kebab）と旧 camelCase struct の両方で読めるだけ読み、
  /// 現行の key 空間である新形式を上に重ねる。camelCase は kebab と綴りが重ならないので、旧が埋める
  /// のは新が言わない項目だけ——唯一重なる `theme` は新形式の読みが勝つ。形式を先に判定しないのは、
  /// 判定の手掛かりになる「新形式として読めるか」がその `theme` の重なりで崩れ、旧形式ファイルを
  /// 新形式と誤認して残りの項目を全部落とすため。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    rootPath = try c.decode(String.self, forKey: .rootPath)
    activeTab = try c.decode(Int.self, forKey: .activeTab)
    tabs = try c.decode([LegacyTabState].self, forKey: .tabs)
    lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)

    guard c.contains(.settingsOverride) else {
      settingsOverride = nil
      return
    }
    let new = (try? c.decode(SettingsLayer.self, forKey: .settingsOverride)) ?? SettingsLayer()
    let old = try? c.decode(LegacyWorkspaceSettingsOverride.self, forKey: .settingsOverride)
    let merged = (old?.toLayer() ?? SettingsLayer()).overlaid(with: new)
    settingsOverride = merged.isEmpty ? nil : merged
  }

  /// 各旧タブの葉を深さ優先順に 1 葉 = 1 タブへ展開して連結する。明示タイトルは先頭の葉へ、
  /// `activeTab` は旧アクティブタブの先頭葉の新 index へ写す。葉の cwd が nil なら workspace の
  /// `rootPath`（0 タブ時の新タブ cwd と同じ fallback）。範囲外の旧 `activeTab` は `restore(from:)`
  /// のクランプに任せる。
  func migrated() -> WorkspaceState {
    var flat: [TabState] = []
    var newActive = activeTab
    for (i, tab) in tabs.enumerated() {
      if i == activeTab { newActive = flat.count }
      let leaves = tab.tree.leaves
      for (j, leaf) in leaves.enumerated() {
        flat.append(
          TabState(
            cwd: leaf.cwd ?? rootPath, agent: leaf.agent,
            explicitTitle: j == 0 ? tab.explicitTitle : nil))
      }
    }
    return WorkspaceState(
      name: name, rootPath: rootPath, activeTab: newActive, tabs: flat,
      lastUsedAt: lastUsedAt, settingsOverride: settingsOverride)
  }
}

/// 旧 workspaces.json の設定上書き（camelCase・scopable 7 設定）。
private struct LegacyWorkspaceSettingsOverride: Decodable {
  var fontSize: Int?
  var backgroundOpacity: Int?
  var backgroundBlur: Bool?
  var theme: ThemeMode?
  var fontFamily: String?
  var cursorStyleBlink: Bool?
  var agentStateIcons: [String: String]?

  /// 新形式レイヤへ（nil は載せない）。ThemeMode は旧 raw と新 `.string` で表現が同じ。
  func toLayer() -> SettingsLayer {
    var layer = SettingsLayer()
    layer[SettingKeys.fontSize] = fontSize
    layer[SettingKeys.backgroundOpacity] = backgroundOpacity
    layer[SettingKeys.backgroundBlur] = backgroundBlur
    layer[SettingKeys.theme] = theme
    layer[SettingKeys.fontFamily] = fontFamily
    layer[SettingKeys.cursorStyleBlink] = cursorStyleBlink
    layer[SettingKeys.agentStateIcons] = agentStateIcons
    return layer
  }
}

/// 旧タブ。v3 は `{ tree, explicitTitle }`、v2 はタブ＝素の `LegacySplitTree`（explicitTitle 無し）。
private struct LegacyTabState: Decodable {
  var tree: LegacySplitTree
  var explicitTitle: String?

  enum CodingKeys: String, CodingKey { case tree, explicitTitle }

  init(from decoder: Decoder) throws {
    if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.tree) {
      tree = try c.decode(LegacySplitTree.self, forKey: .tree)
      explicitTitle = try c.decodeIfPresent(String.self, forKey: .explicitTitle)
    } else {
      tree = try LegacySplitTree(from: decoder)
      explicitTitle = nil
    }
  }
}

/// 旧タブの分割ツリー（二分木）。葉＝cwd・エージェントセッション、節＝向き・分割比。
private indirect enum LegacySplitTree: Decodable {
  case leaf(cwd: String?, agent: AgentSession?)
  case split(vertical: Bool, ratio: Double, first: LegacySplitTree, second: LegacySplitTree)

  /// 葉を深さ優先順に並べる。
  var leaves: [(cwd: String?, agent: AgentSession?)] {
    switch self {
    case .leaf(let cwd, let agent): return [(cwd, agent)]
    case .split(_, _, let first, let second): return first.leaves + second.leaves
    }
  }
}
