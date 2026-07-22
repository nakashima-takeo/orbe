import Foundation

/// root でのキー操作の意味。stepper は ←→ で増減（fontSize）、toggle は ←/→/↵ で反転（cursor-style-blink）、
/// drillIn は ↵/→ でサブパレットへ潜る。値域・既定は `domain`/`defaultValue` が持つ（activation は操作種別のみ）。
enum RootActivation: Equatable { case stepper, toggle, drillIn }

/// 設定値の値域（検証と control の domain 提示・永続 codec の型決定の SSOT）。
enum SettingDomain {
  case intRange(ClosedRange<Int>, step: Int, unit: String)
  case toggle
  /// theme（固定3値）・fontFamily（FontCatalog）・defaultAgent（検出済み）等の列挙。
  case enumeration(values: () -> [String])
  /// agentStateIcons（状態名→SF Symbol 名）。allowedKeys は提示用（値域として縛らない）。
  case stringMap(allowedKeys: () -> [String])

  /// control config_list の type 提示。
  var typeName: String {
    switch self {
    case .intRange: return "int"
    case .toggle: return "bool"
    case .enumeration: return "enum"
    case .stringMap: return "map"
    }
  }

  /// JSON 値を検証して `SettingValue` へ（型不一致・値域外は nil）。control config_set の唯一の検証点。
  func validate(_ jsonValue: Any) -> SettingValue? {
    switch self {
    case .intRange(let range, _, _):
      guard let v = jsonValue as? Int, range.contains(v) else { return nil }
      return .int(v)
    case .toggle:
      guard let v = jsonValue as? Bool else { return nil }
      return .bool(v)
    case .enumeration(let values):
      guard let s = jsonValue as? String else { return nil }
      // 空の値域は「静的に閉じていない開いた列挙」＝任意文字列を受ける（defaultAgent は検出済みが
      // 動的なため静的値域を持たず、未検出のコマンド名も設定として保存できる）。theme/fontFamily は
      // 非空の閉じた値域で membership 検証する。
      let allowed = values()
      guard allowed.isEmpty || allowed.contains(s) else { return nil }
      return .string(s)
    case .stringMap:
      // マップの key を状態名・値を SF Symbol 文字列として受ける（curated 外の symbol も許す）。
      guard let m = jsonValue as? [String: String] else { return nil }
      return .stringMap(m)
    }
  }

  /// 永続 decode: canonical key の JSON 値を domain の型で読む（`SettingsLayer` の codec が使う）。
  func decodeValue<K: CodingKey>(from c: KeyedDecodingContainer<K>, forKey key: K) throws
    -> SettingValue
  {
    switch self {
    case .intRange: return .int(try c.decode(Int.self, forKey: key))
    case .toggle: return .bool(try c.decode(Bool.self, forKey: key))
    case .enumeration: return .string(try c.decode(String.self, forKey: key))
    case .stringMap: return .stringMap(try c.decode([String: String].self, forKey: key))
    }
  }
}

/// 設定項目 1 件の唯一の宣言。解決・検証・永続・control 列挙・gui.conf 発行・パレット既定の行機構が
/// この descriptor 走査で自動追従する（項目追加は 1 件書き `all`/`rootOrder` に位置を入れ typed key を 1 行）。
struct SettingDescriptor {
  let id: SettingID
  /// canonical key（kebab）。ディスク JSON・control・CLI で共通の唯一の key 空間。
  let key: String
  /// パレット表示ラベルの辞書キー（表示時に現在言語で解決する）。
  let labelKey: L10nKey
  /// root でのキー操作種別（stepper/toggle/drillIn）。
  let activation: RootActivation
  /// 解決チェーン最下層の既定（未設定時の値）。nil＝既定なし（fontFamily/defaultAgent の「未設定」）。
  /// devFeatures はビルド種別依存なので closure。
  let defaultValue: () -> SettingValue?
  /// 検証と control の domain 提示の SSOT。
  let domain: SettingDomain
  /// gui.conf 1 行を組む（nil＝gui.conf 非経由）。発行順は `all` の正準順。実効設定の raw を読む
  /// （未設定は行を出さない＝既定へは解決しない）。
  let guiConf: ((EffectiveSettings) -> String?)?
  /// 値の表示語彙（Npt/N%/オン・オフ/label/マップ要約）を現在言語で組む。パレットの現在値表示・WS 上書き注記が共有する。
  let display: (SettingValue, LocalizationStore) -> String
  /// drillIn 項目の未設定表示の辞書キー（nil＝空文字。stepper/toggle は nil）。
  let unsetPlaceholderKey: L10nKey?

  var isDrillIn: Bool { activation == .drillIn }
}

/// 設定項目を 1 箇所で宣言するレジストリ（SSOT）。
enum SettingsRegistry {
  /// フォント未設定時に実際に効く既定フォント（`app/orbe-defaults.conf` の層1 チェーン先頭
  /// `font-family = JetBrainsMono Nerd Font` と対応）。
  static let defaultFontFamily = "JetBrainsMono Nerd Font"

  private static func opacityLabel(_ v: SettingValue) -> String {
    if case .int(let n) = v { return "\(n)%" }
    return ""
  }
  private static func boolLabel(_ v: SettingValue, _ store: LocalizationStore) -> String {
    if case .bool(let b) = v { return store.string(b ? .settingsToggleOn : .settingsToggleOff) }
    return ""
  }

  /// 現行 `~/.config/ghostty` 相当の emoji 60 点集合（emoji-presentation かつ JuliaMono が
  /// 白黒字形で横取りする点）。Apple 選択時の map 先に使う（JuliaMono 横取り防止は Apple でも必須）。
  static let appleEmojiConfValue =
    "U+231A-U+231B,U+23E9-U+23EC,U+23F0,U+23F3,U+26AA-U+26AB,U+26BD-U+26BE,U+26C4-U+26C5,"
    + "U+26CE,U+26D4,U+26EA,U+26F2-U+26F3,U+26F5,U+26FA,U+26FD,U+2705,U+270A-U+270B,U+2728,"
    + "U+274C,U+274E,U+2753-U+2755,U+2757,U+2795-U+2797,U+27B0,U+27BF,U+2B1B-U+2B1C,U+2B50,"
    + "U+2B55,U+1F004,U+1F0CF,U+1F18E,U+1F191-U+1F19A,U+1F201,U+1F4AC,U+1F5E8,U+1F6DC,"
    + "U+1F7F0,U+1FA9D"

  /// 格納/gui.conf 生成の正準順（font-size → font-family → tab-title-font-family〔gui.conf 非経由〕→
  /// emoji-font → theme → agent → background-opacity → background-blur → cursor-style-blink →
  /// agent-state-icons〔gui.conf 非経由〕→ dev-features〔同〕）。
  /// `rootOrder`（表示順）とは別物——混同すると gui.conf のバイト順が崩れる。
  static let all: [SettingDescriptor] = [
    SettingDescriptor(
      id: .fontSize, key: "font-size", labelKey: .settingsFontSize, activation: .stepper,
      defaultValue: { .int(12) }, domain: .intRange(6...72, step: 1, unit: "pt"),
      guiConf: { $0.layer[SettingKeys.fontSize].map { "font-size = \($0)" } },
      display: { v, _ in if case .int(let n) = v { return "\(n)pt" } else { return "" } },
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .fontFamily, key: "font-family", labelKey: .settingsFontFamily, activation: .drillIn,
      defaultValue: { nil }, domain: .enumeration(values: { FontCatalog.names() }),
      // gui.conf は解決順の最後（層3）で append される。層1の既定チェーンへ単純追記すると選択フォントが
      // 末尾に回り無視されるため、`font-family = ""` でチェーンを reset し選択をプライマリ・JuliaMono を
      // 末尾 fallback に据え直す3行を吐く。
      guiConf: {
        $0.layer[SettingKeys.fontFamily].map {
          "font-family = \"\"\nfont-family = \($0)\nfont-family = JuliaMono"
        }
      },
      display: { v, _ in if case .string(let s) = v { return s } else { return "" } },
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .tabTitleFontFamily, key: "tab-title-font-family", labelKey: .settingsTabTitleFont,
      activation: .drillIn,
      // 開いた列挙（defaultAgent 前例）: 任意の family 名を受理する。パレットの列挙候補は
      // FontCatalog.allNames() を提示側が差す。解決不能名は保存値として保持し、描画時解決で
      // 既定（システム等幅 11pt）へ退避する（ChromeFontResolver）。
      defaultValue: { nil }, domain: .enumeration(values: { [] }),
      guiConf: nil,  // gui.conf 非経由（端末に影響しない chrome 専用。resolver 直配信）
      display: { v, _ in if case .string(let s) = v { return s } else { return "" } },
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .emojiFont, key: "emoji-font", labelKey: .settingsEmojiFont, activation: .drillIn,
      defaultValue: { .string(EmojiFontMode.noto.rawValue) },
      domain: .enumeration(values: { EmojiFontMode.allCases.map(\.rawValue) }),
      // font-codepoint-map 行を常時 emit（theme の定数行前例・実効値で map 先だけが変わる）。
      // 非 fallback の font-family（JuliaMono 等）は presentation を無視してグリフ有無だけで選ばれるため、
      // map 無しでは emoji が白黒字形で横取りされる。codepoint-map は解決順の最上位で名前解決し色描画を
      // 決定論化する。noto は emoji-presentation 全域を同梱 Noto（sbix・.process 登録済み）へ、apple は
      // JuliaMono が横取りする 60 点だけを Apple Color Emoji へ充てる（それ以外はハードコード fallback の
      // Apple が既に描く）。map 先未保有 codepoint は libghostty が hasCodepoint 検証で通常解決へ落とすため
      // tofu にならない（vendor CodepointResolver.getIndexCodepointOverride）。
      guiConf: { settings in
        switch settings[SettingKeys.emojiFont] {
        case .noto:
          return "font-codepoint-map = \(EmojiPresentationRanges.confValue)=Noto Color Emoji"
        case .apple:
          return "font-codepoint-map = \(appleEmojiConfValue)=Apple Color Emoji"
        }
      },
      display: { v, store in
        guard case .string(let raw) = v, let mode = EmojiFontMode(rawValue: raw) else { return "" }
        return store.string(mode.labelKey)
      },
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .theme, key: "theme", labelKey: .settingsTheme, activation: .drillIn,
      defaultValue: { .string(ThemeMode.auto.rawValue) },
      domain: .enumeration(values: {
        [ThemeMode.auto.rawValue, ThemeMode.light.rawValue, ThemeMode.dark.rawValue]
      }),
      // 値非依存の定数行を常時吐く。目的はユーザー `~/.config/ghostty` の theme 指定を層3の後勝ちで
      // 恒久無効化し、端末色を Orbe の端末テーマ 2 枚に固定すること。ライト/ダークどちらに見せるかはこの行では
      // なく ThemeMode（NSApp.appearance・applyActiveWorkspaceConfig）が決める。
      guiConf: { _ in "theme = light:OrbeLight,dark:OrbeDark" },
      display: { v, _ in
        if case .string(let s) = v { return ThemeMode(rawValue: s)?.label ?? s } else { return "" }
      },
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .defaultAgent, key: "default-agent", labelKey: .settingsDefaultAgent,
      activation: .drillIn,
      defaultValue: { nil }, domain: .enumeration(values: { [] }),  // 検出済み一覧は control 側で動的に差す
      guiConf: nil,  // gui.conf 非経由（AgentLauncher 直行）
      display: { v, _ in if case .string(let s) = v { return s } else { return "" } },
      unsetPlaceholderKey: .settingsUnset),
    SettingDescriptor(
      id: .backgroundOpacity, key: "background-opacity", labelKey: .settingsBackgroundOpacity,
      activation: .stepper,
      defaultValue: { .int(95) }, domain: .intRange(20...100, step: 1, unit: "%"),
      // percent Int を真実の値として持ち、書き出し時のみ /100（整数演算で誤差を避ける）。%.2f で 2 桁固定。
      guiConf: {
        $0.layer[SettingKeys.backgroundOpacity].map {
          String(format: "background-opacity = %.2f", Double($0) / 100)
        }
      },
      display: { v, _ in opacityLabel(v) }, unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .backgroundBlur, key: "background-blur", labelKey: .settingsBackgroundBlur,
      activation: .toggle,
      defaultValue: { .bool(true) }, domain: .toggle,
      // Swift Bool 補間で true/false（ghostty の期待構文）。true=既定強度20 のすりガラス、false=無ブラー。
      guiConf: { $0.layer[SettingKeys.backgroundBlur].map { "background-blur = \($0)" } },
      display: boolLabel, unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .cursorStyleBlink, key: "cursor-style-blink", labelKey: .settingsCursorBlink,
      activation: .toggle,
      defaultValue: { .bool(true) }, domain: .toggle,  // 既定 conf の cursor-style-blink = true と一致
      guiConf: { $0.layer[SettingKeys.cursorStyleBlink].map { "cursor-style-blink = \($0)" } },
      display: boolLabel, unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .agentStateIcons, key: "agent-state-icons", labelKey: .settingsAgentIcons,
      activation: .drillIn,
      defaultValue: { .stringMap([:]) },
      domain: .stringMap(allowedKeys: { AgentStateIcon.Kind.allCases.map(\.state) }),
      guiConf: nil,  // gui.conf 非経由（chrome が AgentIconResolver 経由で直接描く）
      display: { v, store in
        if case .stringMap(let m) = v {
          let n = AgentStateIcon.decode(m).count
          return n == 0
            ? store.string(.settingsIconsDefault)
            : store.plural(n, one: .settingsIconsCustomOne, other: .settingsIconsCustomOther)
        }
        return ""
      },
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .devFeaturesEnabled, key: "dev-features", labelKey: .settingsDevFeatures,
      activation: .toggle,
      defaultValue: { .bool(isDevBuild) },  // 未設定 default はビルド種別（dev=on/release=off）
      domain: .toggle,
      guiConf: nil,  // gui.conf 非経由（右バーの UI gate 専用）
      display: boolLabel, unsetPlaceholderKey: nil),
  ]

  /// パレット root の表示順（fontSize → backgroundOpacity → backgroundBlur → cursorStyleBlink →
  /// theme → agent → fontFamily → tabTitleFontFamily → emojiFont → agentStateIcons →
  /// devFeaturesEnabled）。背景関連・フォント関連をそれぞれ隣接させる。
  static let rootOrder: [SettingDescriptor] =
    [
      SettingID.fontSize, .backgroundOpacity, .backgroundBlur, .cursorStyleBlink, .theme,
      .defaultAgent, .fontFamily, .tabTitleFontFamily, .emojiFont, .agentStateIcons,
      .devFeaturesEnabled,
    ].map { id in all.first { $0.id == id }! }

  static func descriptor(_ id: SettingID) -> SettingDescriptor { all.first { $0.id == id }! }

  /// canonical key（config CLI・control config_* が使う安定 key）。descriptor の `key` field を引く。
  static func confKey(_ id: SettingID) -> String { descriptor(id).key }

  /// stepper 項目の値域（range/step/unit）。テストが値域を assert する際のアクセサ
  /// （本番は `descriptor(id).domain` の `.intRange` を直接分解する）。
  struct StepperDomain {
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
  }

  /// stepper 項目の値域を取り出す（stepper でない項目は precondition 失敗）。
  static func stepperDomain(_ id: SettingID) -> StepperDomain {
    guard case .intRange(let range, let step, let unit) = descriptor(id).domain else {
      preconditionFailure("\(id) domain must be intRange")
    }
    return StepperDomain(range: range, step: step, unit: unit)
  }
}
