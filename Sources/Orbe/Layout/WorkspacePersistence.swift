import Foundation

/// workspace 構成のディスク永続（自前 JSON）。
/// 保存先は `StateDir.base()/workspaces.json`（既定は `~/Library/Application Support/<bundle-id>/`）。

struct WorkspacesFile: Codable, Equatable {
  var version: Int
  var activeWorkspace: Int
  var workspaces: [WorkspaceState]
  /// 終了時のウィンドウサイズ（幅・高さ）。位置は記憶しない。
  /// optional——旧 JSON（欠落）でも decode 成功し後方互換、無ければ既定 800×500。
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

/// 旧 workspaces.json の設定上書き（camelCase・scopable 7 設定）。移行 decode 専用（将来消せる）。
private struct LegacyWorkspaceSettingsOverride: Codable {
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

struct WorkspaceState: Codable, Equatable {
  var name: String
  var rootPath: String
  var activeTab: Int
  var tabs: [TabState]
  /// この workspace に最後に切り替えてフォーカスした時刻（MRU 並べ替えのキー）。
  /// optional——旧 JSON（欠落）でも decode 成功し後方互換、無ければ nil（最古扱い）。
  var lastUsedAt: Date?
  /// この workspace の設定上書き層（全設定を上書き可）。
  /// optional——旧 JSON（欠落）でも decode 成功し後方互換、無ければ nil（上書き無し＝global 継承）。
  var settingsOverride: SettingsLayer?

  enum CodingKeys: String, CodingKey {
    case name, rootPath, activeTab, tabs, lastUsedAt, settingsOverride
  }

  init(
    name: String, rootPath: String, activeTab: Int, tabs: [TabState],
    lastUsedAt: Date? = nil, settingsOverride: SettingsLayer? = nil
  ) {
    self.name = name
    self.rootPath = rootPath
    self.activeTab = activeTab
    self.tabs = tabs
    self.lastUsedAt = lastUsedAt
    self.settingsOverride = settingsOverride
  }

  /// settingsOverride は新形式（canonical key）を strict decode で試し、未知 key で throw したら旧 camelCase
  /// struct で読んで変換する。field 局所の寛容 decode（`TabState` と同じ家風）で全体を throw させない。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    rootPath = try c.decode(String.self, forKey: .rootPath)
    activeTab = try c.decode(Int.self, forKey: .activeTab)
    tabs = try c.decode([TabState].self, forKey: .tabs)
    lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)

    guard c.contains(.settingsOverride) else {
      settingsOverride = nil
      return
    }
    let layer: SettingsLayer?
    if let sub = try? c.superDecoder(forKey: .settingsOverride),
      let strict = try? SettingsLayer.decode(from: sub, strictUnknownKeys: true)
    {
      layer = strict  // 新形式
    } else if let legacy = try? c.decode(
      LegacyWorkspaceSettingsOverride.self, forKey: .settingsOverride)
    {
      layer = legacy.toLayer()  // 旧 camelCase → 変換（次回 save で新形式へ）
    } else {
      layer = nil
    }
    settingsOverride = (layer?.isEmpty ?? true) ? nil : layer
  }
}

/// タブごとの EditorPane 画面状態の永続表現（粗粒度）。開閉と、開いているツールだけを持つ。
/// 選択ファイル等は復元しない（パス依存で脆いため）。
struct EditorPaneTabState: Codable, Equatable {
  var open: Bool
  var tool: String  // "tree" | "git" | "browser"
}

/// 1 タブの永続表現。分割ツリー（tree）＋ tab 単位メタ（① 明示タイトル ② EditorPane 画面状態）。
/// 旧形式（タブ＝素の PaneNode）も nil 明示タイトルとして読めるよう Decodable をカスタムする。
struct TabState: Codable, Equatable {
  var tree: PaneNode
  var explicitTitle: String?
  var editor: EditorPaneTabState

  enum CodingKeys: String, CodingKey { case tree, explicitTitle, editor }

  static let defaultEditor = EditorPaneTabState(open: false, tool: "tree")

  init(tree: PaneNode, explicitTitle: String?, editor: EditorPaneTabState = defaultEditor) {
    self.tree = tree
    self.explicitTitle = explicitTitle
    self.editor = editor
  }

  init(from decoder: Decoder) throws {
    // 新形式: { "tree": <PaneNode>, "explicitTitle": <String?>, "editor": <EditorPaneTabState> }
    if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.tree) {
      tree = try c.decode(PaneNode.self, forKey: .tree)
      explicitTitle = try c.decodeIfPresent(String.self, forKey: .explicitTitle)
      editor = try c.decode(EditorPaneTabState.self, forKey: .editor)
    } else {
      // 旧形式: タブ＝素の PaneNode（explicitTitle 無し → nil）。
      tree = try PaneNode(from: decoder)
      explicitTitle = nil
      editor = Self.defaultEditor
    }
  }
  // encode(to:) は CodingKeys から自動合成（新形式で書く）。
}

/// ペインで走るエージェントセッション（resume 復開に必要な識別子）。
struct AgentSession: Codable, Equatable {
  var command: String
  var sessionId: String
}

/// 1 タブの分割ツリー（二分木）。葉＝1 ペイン（cwd・エージェントセッション）、節＝1 分割（向き・分割比）。
indirect enum PaneNode: Codable, Equatable {
  case leaf(cwd: String?, agent: AgentSession?)
  case split(vertical: Bool, ratio: Double, first: PaneNode, second: PaneNode)

  /// この分割ツリーが持つ agent != nil の leaf 数（永続 agent セッションの総数）。
  var agentLeafCount: Int {
    switch self {
    case .leaf(_, let agent): return agent != nil ? 1 : 0
    case .split(_, _, let first, let second): return first.agentLeafCount + second.agentLeafCount
    }
  }
}

enum WorkspacePersistence {
  static let version = 3

  /// テスト用に保存先を差し替える（設定時はこちらを使う）。本番は nil。
  static var fileURLOverride: URL?

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("workspaces.json")
  }

  /// 読み込み。欠落・壊れ・非互換 version は nil（呼び出し側が既定で fallback）。
  /// 旧 v2（タブ＝素の PaneNode）も TabState のカスタム Decodable で読める。
  /// 受理後、次回 save で snapshotFile が version:3 で書き直す＝自動移行。
  static func load() -> WorkspacesFile? {
    guard let url = fileURL, let data = try? Data(contentsOf: url),
      let file = try? JSONDecoder().decode(WorkspacesFile.self, from: data),
      file.version == 2 || file.version == version, !file.workspaces.isEmpty
    else { return nil }
    return file
  }

  static func save(_ file: WorkspacesFile) {
    guard let url = fileURL else { return }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(file) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
