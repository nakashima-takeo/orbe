import Foundation
import OrbeEditorCore

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
  /// worktree パレットで前回新しいブランチを作ったときのベース（ブランチ名）。
  /// optional——一度も作っていない workspace では書かれない。
  var lastWorktreeBase: String?
  /// `Workspace.persistentId`。無いか読めない workspace にはその workspace だけ新しく振る（旧形式から
  /// 読んだ場合も同じ）——後から足したフィールドの異常でファイル全体を落とさない。
  var persistentId: UUID

  enum CodingKeys: String, CodingKey {
    case name, rootPath, activeTab, tabs, lastUsedAt, settingsOverride, lastWorktreeBase
    case persistentId
  }

  init(
    name: String, rootPath: String, activeTab: Int, tabs: [TabState],
    lastUsedAt: Date? = nil, settingsOverride: SettingsLayer? = nil,
    lastWorktreeBase: String? = nil, persistentId: UUID = UUID()
  ) {
    self.name = name
    self.rootPath = rootPath
    self.activeTab = activeTab
    self.tabs = tabs
    self.lastUsedAt = lastUsedAt
    self.settingsOverride = settingsOverride
    self.lastWorktreeBase = lastWorktreeBase
    self.persistentId = persistentId
  }

  /// settingsOverride は 1 キー単位で寛容に読む（`SettingsLayer` 自身の decode）——未知 key・型不一致の
  /// 1 項目で層ごと失わない（global 層と同じ家風）。読めた項目が 1 つも無ければ nil（上書き無し＝global 継承）。
  /// lastWorktreeBase も読めなければ nil（前回が無いだけで、workspace は失わない）。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    rootPath = try c.decode(String.self, forKey: .rootPath)
    activeTab = try c.decode(Int.self, forKey: .activeTab)
    tabs = try c.decode([TabState].self, forKey: .tabs)
    lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    let layer = try? c.decode(SettingsLayer.self, forKey: .settingsOverride)
    settingsOverride = layer.flatMap { $0.isEmpty ? nil : $0 }
    lastWorktreeBase = try? c.decodeIfPresent(String.self, forKey: .lastWorktreeBase)
    persistentId = (try? c.decode(UUID.self, forKey: .persistentId)) ?? UUID()
  }
}

/// タブのエディターの状態——開いていた文書と、プロジェクト検索の問い（検索語と 3 つの切替。結果は持たない）。文書が無く
/// 問いが既定なら空で、書かない。JSON は 1 段（`open` / `active` / `search`）で、既定の問いは書かず、読めない項目はその
/// 項目だけを落とす（既定へ）。
struct EditorState: Codable, Equatable {
  var documents: OpenDocuments?
  var search: SearchQuery

  /// 開いていた文書の列（実体パス）と、その中のアクティブと仮のタブ。位置ではなくパスで指す——復元で読めないパスを落としても
  /// 列がずれず、「列があるのにアクティブが無い」という表せない状態を持たない（落ちていれば先頭。仮は無しへ）。
  struct OpenDocuments: Equatable {
    var open: [String]
    var active: String
    var preview: String?
  }

  /// `CaseIterable` は TabState と同じ seam（encode / decode を手書きにしたので、足したキーの書き忘れを全キーの往復テストが見る）。
  enum CodingKeys: String, CodingKey, CaseIterable {
    case open, active, preview, search
  }

  init(documents: OpenDocuments? = nil, search: SearchQuery = SearchQuery()) {
    self.documents = documents
    self.search = search
  }

  /// 空（書くものが無い）か。
  var isEmpty: Bool { documents == nil && search == SearchQuery() }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let open = try? c.decode([String].self, forKey: .open), !open.isEmpty,
      let active = try? c.decode(String.self, forKey: .active)
    {
      documents = OpenDocuments(
        open: open, active: active, preview: try? c.decodeIfPresent(String.self, forKey: .preview))
    }
    search = (try? c.decodeIfPresent(SearchQuery.self, forKey: .search)) ?? SearchQuery()
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if let documents {
      try c.encode(documents.open, forKey: .open)
      try c.encode(documents.active, forKey: .active)
      try c.encodeIfPresent(documents.preview, forKey: .preview)
    }
    if search != SearchQuery() { try c.encode(search, forKey: .search) }
  }
}

/// 1 タブの永続表現。cwd・エージェントセッション・明示タイトル・面の配置・エディターの状態。
struct TabState: Codable, Equatable {
  var cwd: String
  var agent: AgentSession?
  var explicitTitle: String?
  /// 面の配置。既定（端末だけ）は書かず、読めなければ既定へ落とす（ファイル全体は失わない）。
  var faces: FaceLayout
  /// エディターの状態（開いていた文書・検索の問い）。無ければ書かず、読めなければ nil へ落とす（ファイル全体は失わない）。
  var editor: EditorState?

  /// `CaseIterable` は「フィールドを足して encode / decode を忘れる」を検出する seam
  /// （`WorkspacePersistenceTests` が全キーの往復を見る）。
  enum CodingKeys: String, CodingKey, CaseIterable {
    case cwd, agent, explicitTitle, faces, editor
  }

  init(
    cwd: String, agent: AgentSession?, explicitTitle: String?, faces: FaceLayout = .terminalOnly,
    editor: EditorState? = nil
  ) {
    self.cwd = cwd
    self.agent = agent
    self.explicitTitle = explicitTitle
    self.faces = faces
    self.editor = editor
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    cwd = try c.decode(String.self, forKey: .cwd)
    agent = try c.decodeIfPresent(AgentSession.self, forKey: .agent)
    explicitTitle = try c.decodeIfPresent(String.self, forKey: .explicitTitle)
    faces = ((try? c.decode(FaceLayout.self, forKey: .faces)) ?? .terminalOnly).normalized
    editor = (try? c.decode(EditorState.self, forKey: .editor)).flatMap { $0.isEmpty ? nil : $0 }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(cwd, forKey: .cwd)
    try c.encodeIfPresent(agent, forKey: .agent)
    try c.encodeIfPresent(explicitTitle, forKey: .explicitTitle)
    if faces != .terminalOnly { try c.encode(faces, forKey: .faces) }
    if let editor, !editor.isEmpty { try c.encode(editor, forKey: .editor) }
  }
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
