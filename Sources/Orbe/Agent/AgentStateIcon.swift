/// エージェント状態インジケータの種別（Orbe 正典グリフに対応）。
/// idle は横断ロールアップにのみ出す（タブには出ない＝`TerminalController.aggregateAgentState` の
/// priority が担う）。描画・色・モーションは `StatusGlyph.swift`（`Kind` から一意に解決）。
/// 典拠は wezterm-ai-agents プラグインの状態。
enum AgentStateIcon {
  /// 状態グリフの種別。色は種別から一意に決まるためここでは持たない（二重管理を避ける）。
  /// 宣言順（working/waiting/done/idle/dormant）が設定パレットの状態一覧の並び。
  enum Kind: Hashable, CaseIterable {
    case working, waiting, done, idle, dormant
  }

  /// 状態→種別。`Kind.state` を SSOT に逆引き表を導く（状態文字列の二重定義を作らない）。
  private static let kinds: [String: Kind] = Dictionary(
    uniqueKeysWithValues: Kind.allCases.map { ($0.state, $0) })

  /// 状態から種別を引く。状態なし（nil）・未知の状態は nil。
  static func kind(state: String?) -> Kind? {
    guard let state else { return nil }
    return kinds[state]
  }

  /// 状態ごとに差し替え可能な curated SF Symbols（設定パレットのアイコン候補の SSOT）。
  /// 各候補は状態の意味に合うモノクロ symbol（tint は状態色）。実在は `AgentIconTests` が担保する。
  static let curatedSymbols: [Kind: [String]] = [
    .working: ["gearshape", "arrow.triangle.2.circlepath"],
    .waiting: ["bubble.left", "hourglass"],
    .done: ["checkmark.circle.fill", "checkmark.seal"],
    .idle: ["moon.zzz", "powersleep"],
    .dormant: ["moon.zzz.fill", "zzz"],
  ]

  /// 状態→種別マップ（永続キー）を種別キーの実効マップへ復号する。未知状態キーは捨てる。
  static func decode(_ map: [String: String]?) -> [Kind: String] {
    guard let map else { return [:] }
    var out: [Kind: String] = [:]
    for (state, symbol) in map where !symbol.isEmpty {
      if let k = kind(state: state) { out[k] = symbol }
    }
    return out
  }

  /// 種別キーの実効マップを永続用の状態→種別マップへ符号化する。
  static func encode(_ map: [Kind: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: map.map { ($0.key.state, $0.value) })
  }
}

extension AgentStateIcon.Kind {
  /// 永続キー・逆変換に使う状態文字列（`kinds` 逆引き表の SSOT）。
  var state: String {
    switch self {
    case .working: return "working"
    case .waiting: return "waiting"
    case .done: return "done"
    case .idle: return "idle"
    case .dormant: return "dormant"
    }
  }
}
