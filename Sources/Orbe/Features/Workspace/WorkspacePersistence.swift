import Foundation

/// workspace 構成のディスク永続（自前 JSON）。
/// 保存先は `StateDir.base()/workspaces.json`（既定は `~/Library/Application Support/<bundle-id>/`）。

struct WorkspacesFile: Codable, Equatable {
  var version: Int
  var activeWorkspace: Int
  var workspaces: [WorkspaceState]
  /// 終了時のウィンドウサイズ（幅・高さ）。位置は記憶しない。
  /// optional——一度もリサイズしていない起動では書かれない。無ければ既定 800×500。
  var windowSize: WindowSize?

  init(
    version: Int, activeWorkspace: Int, workspaces: [WorkspaceState],
    windowSize: WindowSize? = nil
  ) {
    self.version = version
    self.activeWorkspace = activeWorkspace
    self.workspaces = workspaces
    self.windowSize = windowSize
  }
}

/// 記憶するウィンドウサイズ（位置は含めない）。
struct WindowSize: Codable, Equatable {
  var width: Double
  var height: Double
}

struct WorkspaceState: Codable, Equatable {
  var name: String
  var rootPath: String
  var activeTab: Int
  var tabs: [TabState]
  /// この workspace に最後に切り替えてフォーカスした時刻（MRU 並べ替えのキー）。
  /// optional——一度も前面で使っていない workspace では書かれない（タブ選択でも進む）。無ければ nil（最古扱い）。
  var lastUsedAt: Date?
  /// この workspace の設定上書き層（全設定を上書き可）。
  /// optional——上書きが 1 項目も無ければ書かれない（＝global 継承）。
  var settingsOverride: SettingsLayer?
  /// `Workspace.persistentId`。無いか読めない workspace にはその workspace だけ新しく振る（旧形式から
  /// 読んだ場合も同じ）——後から足したフィールドの異常でファイル全体を落とさない。
  var persistentId: UUID

  enum CodingKeys: String, CodingKey {
    case name, rootPath, activeTab, tabs, lastUsedAt, settingsOverride, persistentId
  }

  init(
    name: String, rootPath: String, activeTab: Int, tabs: [TabState],
    lastUsedAt: Date? = nil, settingsOverride: SettingsLayer? = nil, persistentId: UUID = UUID()
  ) {
    self.name = name
    self.rootPath = rootPath
    self.activeTab = activeTab
    self.tabs = tabs
    self.lastUsedAt = lastUsedAt
    self.settingsOverride = settingsOverride
    self.persistentId = persistentId
  }

  /// settingsOverride は 1 キー単位で寛容に読む（`SettingsLayer` 自身の decode）——未知 key・型不一致の
  /// 1 項目で層ごと失わない（global 層と同じ家風）。読めた項目が 1 つも無ければ nil（上書き無し＝global 継承）。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    rootPath = try c.decode(String.self, forKey: .rootPath)
    activeTab = try c.decode(Int.self, forKey: .activeTab)
    tabs = try c.decode([TabState].self, forKey: .tabs)
    lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    let layer = try? c.decode(SettingsLayer.self, forKey: .settingsOverride)
    settingsOverride = layer.flatMap { $0.isEmpty ? nil : $0 }
    persistentId = (try? c.decode(UUID.self, forKey: .persistentId)) ?? UUID()
  }
}

/// 1 タブの永続表現。cwd・エージェントセッション・明示タイトル。
struct TabState: Codable, Equatable {
  var cwd: String
  var agent: AgentSession?
  var explicitTitle: String?
}

/// タブで走るエージェントセッション＝agent の同一性・再開ハンドル。状態をまたいで持続する
/// （復元で凍結 → 消費で live へ引き継ぎ → 報告で sessionId が後から確定する）。
/// sessionId は optional——報告が sessionId を運ぶ前の稼働（live）を表現する。
struct AgentSession: Codable, Equatable {
  var command: String
  var sessionId: String?
}

enum WorkspacePersistence {
  static let version = 4

  /// テスト用に保存先を差し替える（設定時はこちらを使う）。本番は nil。
  static var fileURLOverride: URL?

  /// 使えなかった原本の退避と、退避できなかった原本への書き込み停止。`load()` が毎回更新する。
  private static var quarantine = StateFileQuarantine()

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("workspaces.json")
  }

  /// 読み込み。欠落・壊れ・非互換 version は nil（呼び出し側が既定で fallback）。
  /// version を先に読み、現行（4）は素直に decode、旧 v2 / v3 は移行専用 decoder
  /// （`WorkspacePersistence+Legacy`）で読んで平坦化する。受理後、次回 save で snapshotFile が
  /// version:4 で書き直す＝自動移行。
  ///
  /// 原本が「在るのに使えない」ときは nil を返す前に退避する。直後の既定起動が打つ save が
  /// `.atomic` write で原本を完全に潰すため、ここで残さないと復元手段が消える。
  /// 不在（初回起動）と空 workspaces は失う構成が無いので退避しない（毎起動のゴミを作らない）。
  static func load() -> WorkspacesFile? {
    quarantine.reset()
    guard let url = fileURL else { return nil }  // 保存先が決まらない。save も同じ guard で書かない
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }  // 初回起動
    guard let data = try? Data(contentsOf: url), let file = decode(data) else {
      quarantine.quarantine(url)  // 読めない・構造破損・非互換 version＝ユーザー構成が入っている原本
      return nil
    }
    guard !file.workspaces.isEmpty else { return nil }  // 中身が無い＝失う構成が無い
    return file
  }

  private struct VersionProbe: Decodable {
    let version: Int
  }

  private static func decode(_ data: Data) -> WorkspacesFile? {
    guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { return nil }
    switch probe.version {
    case version: return try? JSONDecoder().decode(WorkspacesFile.self, from: data)
    case 2, 3: return loadLegacy(data)
    default: return nil
    }
  }

  static func save(_ file: WorkspacesFile) {
    guard let url = fileURL, quarantine.permitsWrite(to: url) else { return }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(file) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
