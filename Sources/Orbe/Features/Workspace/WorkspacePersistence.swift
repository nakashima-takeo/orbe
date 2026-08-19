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

  /// settingsOverride は新形式（canonical key・kebab）と旧 camelCase struct の**両方で読めるだけ読み、
  /// 現行の key 空間である新形式を上に重ねる**。camelCase は kebab と綴りが重ならないので、旧が埋める
  /// のは新が言わない項目だけ——唯一重なる `theme` は新形式の読みが勝つ。形式を先に判定しないのは、
  /// 判定の手掛かりになる「新形式として読めるか」がその `theme` の重なりで崩れ、旧形式ファイルを
  /// 新形式と誤認して残りの項目を全部落とすため。
  /// field 局所の寛容 decode で全体を throw させない。
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
    // 新形式は 1 キー単位で寛容に読む——未知 key・型不一致の 1 項目で層ごと失わない（global 層と
    // 同じ家風）。旧 camelCase struct の decode は all-or-nothing（`loadGlobal` の旧形式移行と同じ）。
    // 現行の key 空間である新形式を上に重ねる（旧 camelCase は新形式が言わない項目だけを埋める）。
    // 読めた項目が 1 つも無ければ nil（上書き無し＝global 継承）。次回 save で新形式へ揃う。
    let new = (try? c.decode(SettingsLayer.self, forKey: .settingsOverride)) ?? SettingsLayer()
    let old = try? c.decode(LegacyWorkspaceSettingsOverride.self, forKey: .settingsOverride)
    let legacy = old?.toLayer() ?? SettingsLayer()
    let merged = legacy.overlaid(with: new)
    settingsOverride = merged.isEmpty ? nil : merged
  }
}

/// 1 タブの永続表現。分割ツリー（tree）＋ tab 単位メタ（明示タイトル）。
/// 旧形式（タブ＝素の PaneNode）も nil 明示タイトルとして読めるよう Decodable をカスタムする。
struct TabState: Codable, Equatable {
  var tree: PaneNode
  var explicitTitle: String?

  enum CodingKeys: String, CodingKey { case tree, explicitTitle }

  init(tree: PaneNode, explicitTitle: String?) {
    self.tree = tree
    self.explicitTitle = explicitTitle
  }

  init(from decoder: Decoder) throws {
    // 新形式: { "tree": <PaneNode>, "explicitTitle": <String?> }
    if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.tree) {
      tree = try c.decode(PaneNode.self, forKey: .tree)
      explicitTitle = try c.decodeIfPresent(String.self, forKey: .explicitTitle)
    } else {
      // 旧形式: タブ＝素の PaneNode（explicitTitle 無し → nil）。
      tree = try PaneNode(from: decoder)
      explicitTitle = nil
    }
  }
  // encode(to:) は CodingKeys から自動合成（新形式で書く）。
}

/// ペインで走るエージェントセッション＝agent の同一性・再開ハンドル。状態をまたいで持続する
/// （復元で凍結 → 消費で live へ引き継ぎ → 報告で sessionId が後から確定する）。
/// sessionId は optional——報告が sessionId を運ぶ前の稼働（live）を表現する。
struct AgentSession: Codable, Equatable {
  var command: String
  var sessionId: String?
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

  /// 退避に失敗して原位置に残っている原本の場所。この URL への `save()` は書かない
  /// ——保全できていない原本を既定 workspace で潰すのは、`.atomic` write で書き込み途中の
  /// 破損を防いでいるのと同じ「原本を壊さない」責務の裏側。`load()` が毎回更新する。
  /// 場所で持つので、保存先が変われば古い判断を引きずらない。
  private(set) static var unsalvagedOriginal: URL?

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("workspaces.json")
  }

  /// 読み込み。欠落・壊れ・非互換 version は nil（呼び出し側が既定で fallback）。
  /// 旧 v2（タブ＝素の PaneNode）も TabState のカスタム Decodable で読める。
  /// 受理後、次回 save で snapshotFile が version:3 で書き直す＝自動移行。
  ///
  /// 原本が「在るのに使えない」ときは nil を返す前に退避する。直後の既定起動が打つ save が
  /// `.atomic` write で原本を完全に潰すため、ここで残さないと復元手段が消える。
  /// 不在（初回起動）と空 workspaces は失う構成が無いので退避しない（毎起動のゴミを作らない）。
  static func load() -> WorkspacesFile? {
    unsalvagedOriginal = nil
    guard let url = fileURL else { return nil }  // 保存先が決まらない。save も同じ guard で書かない
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }  // 初回起動
    guard let data = try? Data(contentsOf: url),
      let file = try? JSONDecoder().decode(WorkspacesFile.self, from: data),
      file.version == 2 || file.version == version
    else {
      quarantine(url)  // 読めない・構造破損・非互換 version＝ユーザー構成が入っている原本
      return nil
    }
    guard !file.workspaces.isEmpty else { return nil }  // 中身が無い＝失う構成が無い
    return file
  }

  /// 使えなかった原本を隣へ退避する（最新 1 件だけ残す）。
  /// 先に古い退避物を消してから move するので、退避先の名前は常に空いている
  /// ——秒精度のタイムスタンプが同一秒で衝突する問題を構造的に持たない。
  /// 消えるのは常により古い控え。退避が 2 回起きる系列では 1 件目（＝ユーザーの構成）が消えて
  /// 2 件目（＝1 回目の後に書かれた既定構成）だけが残るが、毎起動のゴミを積まない方を採る
  /// （prune の失敗はゴミが 1 件残るだけなので退避ガードを立てない）。
  private static func quarantine(_ url: URL) {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    for old in existingQuarantines(in: dir) { try? fm.removeItem(at: old) }

    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let dest = dir.appendingPathComponent("workspaces-broken-\(stamp.string(from: Date())).json")
    do {
      try fm.moveItem(at: url, to: dest)
      NSLog("[workspace] quarantined unreadable workspaces.json to \(dest.path)")
    } catch {
      // 原本が実際に残っているときだけガードを立てる。原本ごと消えていたら守る対象が無く、
      // ここで立てるとそのセッションの構成が無言で一切保存されなくなる。
      guard fm.fileExists(atPath: url.path) else { return }
      unsalvagedOriginal = url
      NSLog("[workspace] quarantine failed, save disabled: \(url.path)")
    }
  }

  /// 同じディレクトリに残っている退避物。
  private static func existingQuarantines(in dir: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let broken = names.filter { $0.hasPrefix("workspaces-broken-") && $0.hasSuffix(".json") }
    return broken.map { dir.appendingPathComponent($0) }
  }

  static func save(_ file: WorkspacesFile) {
    guard let url = fileURL, url != unsalvagedOriginal else { return }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(file) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
