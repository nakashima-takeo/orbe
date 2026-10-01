import Foundation
import OrbeSound

/// root でのキー操作の意味。stepper は ←→ で増減（fontSize）、toggle は ←/→/↵ で反転（cursor-style-blink）、
/// drillIn は ↵/→ でサブパレットへ潜る。値域・既定は `domain`/`defaultValue` が持つ（activation は操作種別のみ）。
enum RootActivation: Equatable { case stepper, toggle, drillIn }

/// 設定値の値域（検証と control の domain 提示・永続 codec の型決定の SSOT）。
enum SettingDomain {
  case intRange(ClosedRange<Int>, step: Int, unit: String)
  case toggle
  /// theme（固定3値）・fontFamily（FontCatalog）・defaultAgent（検出済み）等の列挙。
  case enumeration(values: () -> [String])
  /// agentStateIcons（状態名→SF Symbol 名）・カスタム音源（file/name/duration）。
  /// allowedKeys は提示用（control の domain が名乗る。値域として縛らない）。
  case stringMap(allowedKeys: () -> [String])
  /// worktreeDir（作成先テンプレート）。値域は列挙でなく構文（`WorktreePathTemplate.validate`）で縛る。
  case pathTemplate

  /// control config_list の type 提示。
  var typeName: String {
    switch self {
    case .intRange: return "int"
    case .toggle: return "bool"
    case .enumeration: return "enum"
    case .stringMap: return "map"
    case .pathTemplate: return "string"
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
      // 文字列マップとしてだけ受け、key/値は縛らない（意味づけと parse は各値型が 1 箇所で持つ）。
      guard let m = jsonValue as? [String: String] else { return nil }
      return .stringMap(m)
    case .pathTemplate:
      // 構文検証（未知トークン・{slug} 欠落・相対解決）はテンプレートエンジンに一本化。
      // パレット・orb config・control の全経路がここを通る。
      guard let s = jsonValue as? String, WorktreePathTemplate.validate(s) == nil else {
        return nil
      }
      return .string(s)
    }
  }

  /// 永続 decode: canonical key の JSON 値を domain の型で読む（`SettingsLayer` の codec が使う）。
  /// 値域の担保もここが持つ——ディスクは人が手で書ける入力なので、読んだ値がそのまま実効値に
  /// なると値域は「設定パレット経由でだけ守られる約束」に痩せる。`validate`（control config_set）は
  /// 呼び出し元に拒否を返せるが読出には返す先が無いため、最寄りの端へ丸めて受ける
  /// （既定へ落とすと「大きくしたい／小さくしたい」という書き手の意図まで捨ててしまう）。
  func decodeValue<K: CodingKey>(from c: KeyedDecodingContainer<K>, forKey key: K) throws
    -> SettingValue
  {
    switch self {
    case .intRange(let range, _, _):
      let v = try c.decode(Int.self, forKey: key)
      return .int(min(range.upperBound, max(range.lowerBound, v)))
    case .toggle: return .bool(try c.decode(Bool.self, forKey: key))
    case .enumeration, .pathTemplate: return .string(try c.decode(String.self, forKey: key))
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

  /// 百分率の値表示（背景の不透明度・通知音の音量が共有する）。
  private static func percentLabel(_ v: SettingValue) -> String {
    if case .int(let n) = v { return "\(n)%" }
    return ""
  }
  private static func boolLabel(_ v: SettingValue, _ store: LocalizationStore) -> String {
    if case .bool(let b) = v { return store.string(b ? .settingsToggleOn : .settingsToggleOff) }
    return ""
  }

  /// 秒数の値表示。単位の付け方が言語で割れる（ja は密着・en は空白区切り）ので書式ごと L10n が持つ。
  private static func secondsLabel(_ v: SettingValue, _ store: LocalizationStore) -> String {
    if case .int(let n) = v { return store.format(.settingsSecondsValue, n) }
    return ""
  }

  /// カスタム音源 map の提示用 key（値域として縛らない＝parse は `CustomSoundSource` が 1 箇所で持つ）。
  private static let customSoundKeys = ["file", "name", "duration"]

  /// カスタム音源の値表示は元ファイル名（人が選んだときの手掛かりがそれだけなので）。
  private static func customSoundLabel(_ v: SettingValue, _ store: LocalizationStore) -> String {
    CustomSoundSource(settingValue: v)?.name ?? store.string(.settingsSoundCustomUnset)
  }

  /// 格納/gui.conf 生成の正準順（font-size → font-family → tab-title-font-family〔gui.conf 非経由〕→
  /// emoji-font → theme → agent → background-opacity → background-blur → cursor-style-blink →
  /// agent-state-icons〔gui.conf 非経由〕→ worktree-dir〔同〕→
  /// notification-sound〔同〕→ notification-sound-volume〔同〕→ notification-sound-enabled〔同〕→
  /// notification-sound-custom-done / -waiting / -waiting-same-as-done〔いずれも同〕→
  /// menubar-notification-duration〔同〕）。
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
      // 末尾に回り無視されるため、`font-family = ""` でチェーンを reset して選択をプライマリに据え直す
      // 2行を吐く。層1 と同じくチェーンは 1 本に保つ（font-family の face は presentation を無視して奪う
      // ため、広カバレッジを足すと絵文字が白黒になり記号の解決先も半角字形へすり替わる。
      // 理由の詳細と実測値は `app/orbe-defaults.conf`）。
      guiConf: {
        $0.layer[SettingKeys.fontFamily].map {
          "font-family = \"\"\nfont-family = \($0)"
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
      // noto は「同梱 Noto のフラット字形で描く」という機能そのもの。emoji-presentation 全域を
      // 同梱 Noto（sbix・.process 登録済み）へ map する。codepoint-map は解決順の最上位で名前解決し、
      // map 先未保有 codepoint は libghostty が hasCodepoint 検証で通常解決へ落とすため tofu にならない
      // （vendor CodepointResolver.getIndexCodepointOverride）。
      // apple は map を出さない。libghostty が macOS で Apple Color Emoji を必ず fallback へ挿すため
      // （vendor SharedGridSet.zig）、放っておけばそれが色付きで描く。奪う側の font-family を
      // JetBrains 1 本に絞ってあるので、横取りを打ち消すための map はもう要らない。
      guiConf: { settings in
        switch settings[SettingKeys.emojiFont] {
        case .noto:
          return "font-codepoint-map = \(EmojiPresentationRanges.confValue)=Noto Color Emoji"
        case .apple:
          return nil
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
      display: { v, _ in percentLabel(v) }, unsetPlaceholderKey: nil),
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
      id: .worktreeDir, key: "worktree-dir", labelKey: .settingsWorktreeDir, activation: .drillIn,
      defaultValue: { .string(WorktreePathTemplate.defaultTemplate) },
      domain: .pathTemplate,
      guiConf: nil,  // gui.conf 非経由（Dispatch の worktree 作成時に実効値を pull する）
      display: { v, _ in if case .string(let s) = v { return s } else { return "" } },
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .notificationSound, key: "notification-sound", labelKey: .settingsNotificationSound,
      activation: .drillIn,
      // 既定の選択は `AgentSoundChoice.default`（＝`NotificationSound.default` の案）が SSOT
      // （実機で聴き比べて決め直すときの唯一の差し替え点）。
      defaultValue: { AgentSoundChoice.default.settingValue },
      domain: .enumeration(values: { AgentSoundChoice.allRawValues }),
      guiConf: nil,  // gui.conf 非経由（libghostty 設定ではない）
      display: { v, store in
        guard case .string(let raw) = v, let choice = AgentSoundChoice(rawValue: raw) else {
          return ""
        }
        return store.string(choice.labelKey)
      },
      unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .notificationSoundVolume, key: "notification-sound-volume",
      labelKey: .settingsNotificationSoundVolume, activation: .stepper,
      // 下限は 0 でなく 5——「鳴らない状態」の担体はオン/オフ 1 つに閉じる。0 を許すと
      // サブパレットの試聴まで無音になり、聴きながら選ぶという面の目的が立たなくなる。
      // 既定音量は `SoundRenderer.defaultVolume` が SSOT（リテラルを 2 箇所に置かない）。
      defaultValue: { .int(SoundRenderer.defaultVolume) },
      domain: .intRange(5...100, step: 5, unit: "%"),
      guiConf: nil,  // gui.conf 非経由（合成の入力＝コンプレッサの手前に掛かる）
      display: { v, _ in percentLabel(v) }, unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .notificationSoundEnabled, key: "notification-sound-enabled",
      labelKey: .settingsNotificationSoundEnabled, activation: .toggle,
      defaultValue: { .bool(true) }, domain: .toggle,
      guiConf: nil,  // gui.conf 非経由
      display: boolLabel, unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .notificationSoundCustomDone, key: "notification-sound-custom-done",
      labelKey: .settingsSoundCustomDoneRow, activation: .drillIn,
      defaultValue: { nil },  // 未取り込み（実効は紋章の同 event 音へフォールバック）
      domain: .stringMap(allowedKeys: { customSoundKeys }),
      guiConf: nil,  // gui.conf 非経由
      display: customSoundLabel, unsetPlaceholderKey: .settingsSoundCustomUnset),
    SettingDescriptor(
      id: .notificationSoundCustomWaiting, key: "notification-sound-custom-waiting",
      labelKey: .settingsSoundCustomWaitingRow, activation: .drillIn,
      defaultValue: { nil },
      domain: .stringMap(allowedKeys: { customSoundKeys }),
      guiConf: nil,  // gui.conf 非経由
      display: customSoundLabel, unsetPlaceholderKey: .settingsSoundCustomUnset),
    SettingDescriptor(
      id: .notificationSoundCustomWaitingSameAsDone,
      key: "notification-sound-custom-waiting-same-as-done",
      labelKey: .settingsSoundCustomSameAsDone, activation: .toggle,
      defaultValue: { .bool(true) }, domain: .toggle,
      guiConf: nil,  // gui.conf 非経由
      display: boolLabel, unsetPlaceholderKey: nil),
    SettingDescriptor(
      id: .menuBarNotificationDuration, key: "menubar-notification-duration",
      labelKey: .settingsMenuBarNotificationDuration, activation: .stepper,
      defaultValue: { .int(40) }, domain: .intRange(5...180, step: 5, unit: "s"),
      guiConf: nil,  // gui.conf 非経由（メニューバー chrome の尺で libghostty 設定ではない）
      display: secondsLabel, unsetPlaceholderKey: nil),
  ]

  /// 取り込み済み音源の実体（`sounds/` 配下のファイル）を指す項目。参照集合 GC の契機判定が読む。
  /// 参照集合の収集（`WindowController.collectCustomSoundGarbage`）と同じ `SettingKeys` の 1 列から
  /// 導くので、契機と集合がドリフトしない。
  static let customSoundSourceIDs = Set(SettingKeys.customSoundSources.map(\.id))

  /// root に**行を持たない**項目（`rootOrder` 非掲載）。カスタム音源の 3 件は通知音サブのさらに
  /// 奥（カスタム設定サブ）でだけ編集され、root には「通知音」の 1 行として畳まれて出る
  /// ——`all ⊇ rootOrder` であって等しくはない、という不変条件をこの集合が明示する。
  static let nonRootIDs: Set<SettingID> = [
    .notificationSoundCustomDone, .notificationSoundCustomWaiting,
    .notificationSoundCustomWaitingSameAsDone,
  ]

  /// パレット root の表示順（fontSize → backgroundOpacity → backgroundBlur → cursorStyleBlink →
  /// theme → agent → fontFamily → tabTitleFontFamily → emojiFont → agentStateIcons →
  /// worktreeDir → notificationSound → 音量 → オン/オフ → メニューバー通知の表示時間）。
  /// 背景関連・フォント関連・通知音関連をそれぞれ隣接させる。
  static let rootOrder: [SettingDescriptor] =
    [
      SettingID.fontSize, .backgroundOpacity, .backgroundBlur, .cursorStyleBlink, .theme,
      .defaultAgent, .fontFamily, .tabTitleFontFamily, .emojiFont, .agentStateIcons,
      .worktreeDir, .notificationSound, .notificationSoundVolume,
      .notificationSoundEnabled, .menuBarNotificationDuration,
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
