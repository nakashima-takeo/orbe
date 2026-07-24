import Foundation

/// ⌘H ヘルプの静的カタログ（ショートカット一覧・キーボード物理配列・チップ記号）。
/// 掲載内容の真実の出所は Keybindings.swift / MainMenu.swift / libghostty 既定（手動棚卸し）。
/// 表示キー表記・ラベル・カテゴリ・combo はプレゼンテーション情報でコードから導出できないため
/// 静的に持ち、内部整合（combo⊆KB・厳選⊆カテゴリ行・表示キー一意）は HelpCatalogTests が機械保証する。
enum HelpCatalog {
  /// 一覧の 1 行（1 バインド。同義コマンドの別キーも独立行）。
  /// `combo` はキーボード可視化で点灯する物理キー id 列（`keyboard` の id 語彙）。
  struct Row {
    let key: String
    let label: L10nKey
    let combo: [String]
  }

  /// カテゴリ（サイドバー・一覧のグループ見出し）。
  struct Group {
    let title: L10nKey
    let rows: [Row]
  }

  /// 全ショートカット。並びはトップビュー厳選の導出順（全般 → ワークスペースとタブ → … → ターミナル）を兼ねる。
  static let all: [Group] = [
    Group(
      title: .helpCatGeneral,
      rows: [
        Row(key: "⌘H", label: .helpShortcutHelp, combo: ["cmd", "h"]),
        Row(key: "⌘,", label: .helpShortcutSettings, combo: ["cmd", ","]),
        Row(key: "⌘Q", label: .helpShortcutQuit, combo: ["cmd", "q"]),
      ]),
    Group(
      title: .helpCatWorkspaceTabs,
      rows: [
        Row(key: "⌘⇧S", label: .helpShortcutSwitchWorkspace, combo: ["cmd", "shift", "s"]),
        Row(key: "⌘N", label: .helpShortcutNewWorkspace, combo: ["cmd", "n"]),
        Row(key: "⌘T", label: .helpShortcutNewTab, combo: ["cmd", "t"]),
        Row(key: "⌘R", label: .helpShortcutRenameTab, combo: ["cmd", "r"]),
        Row(key: "⌘⇧]", label: .helpShortcutNextTab, combo: ["cmd", "shift", "]"]),
        Row(key: "⌘⇧[", label: .helpShortcutPrevTab, combo: ["cmd", "shift", "["]),
        Row(key: "⌘⇧→", label: .helpShortcutNextTab, combo: ["cmd", "shift", "right"]),
        Row(key: "⌘⇧←", label: .helpShortcutPrevTab, combo: ["cmd", "shift", "left"]),
      ]),
    Group(
      title: .helpCatPanesEditor,
      rows: [
        Row(key: "⌘D", label: .helpShortcutSplitRight, combo: ["cmd", "d"]),
        Row(key: "⌘⇧D", label: .helpShortcutSplitDown, combo: ["cmd", "shift", "d"]),
        Row(key: "⌘W", label: .helpShortcutClosePane, combo: ["cmd", "w"]),
        Row(key: "⌘/", label: .helpShortcutToggleEditorPane, combo: ["cmd", "/"]),
        Row(key: "⌘⇧E", label: .helpShortcutOpenEditor, combo: ["cmd", "shift", "e"]),
        Row(key: "⌘⇧↑", label: .helpShortcutPrevTool, combo: ["cmd", "shift", "ud"]),
        Row(key: "⌘⇧↓", label: .helpShortcutNextTool, combo: ["cmd", "shift", "ud"]),
      ]),
    Group(
      title: .helpCatAgents,
      rows: [
        Row(key: "⌘⇧C", label: .helpShortcutLaunchDefaultAgent, combo: ["cmd", "shift", "c"]),
        Row(key: "⌘⇧A", label: .helpShortcutAgentPalette, combo: ["cmd", "shift", "a"]),
        Row(key: "⌘⇧X", label: .helpShortcutDispatchPalette, combo: ["cmd", "shift", "x"]),
      ]),
    Group(
      title: .helpCatTerminal,
      rows: [
        Row(key: "⌘F", label: .helpShortcutFind, combo: ["cmd", "f"]),
        Row(key: "⌘↑", label: .helpShortcutScrollTop, combo: ["cmd", "ud"]),
        Row(key: "⌘↓", label: .helpShortcutScrollBottom, combo: ["cmd", "ud"]),
        Row(key: "⌘C", label: .helpShortcutCopy, combo: ["cmd", "c"]),
        Row(key: "⌘V", label: .helpShortcutPaste, combo: ["cmd", "v"]),
        Row(key: "⌘+", label: .helpShortcutFontLarger, combo: ["cmd", "="]),
        Row(key: "⌘-", label: .helpShortcutFontSmaller, combo: ["cmd", "-"]),
        Row(key: "⌘0", label: .helpShortcutFontReset, combo: ["cmd", "0"]),
      ]),
  ]

  /// トップビュー（基本操作）に出す厳選セット（カテゴリ → 表示キー列）。
  static let topPicks: [L10nKey: [String]] = [
    .helpCatGeneral: ["⌘H", "⌘,", "⌘Q"],
    .helpCatWorkspaceTabs: ["⌘⇧S", "⌘N", "⌘T", "⌘⇧]"],
    .helpCatAgents: ["⌘⇧C", "⌘⇧A", "⌘⇧X"],
  ]

  /// トップビュー用グループ（`all` から combo を保持したまま導出。行ホバーのキーボード点灯に使う）。
  static let topGroups: [Group] =
    all
    .filter { topPicks[$0.title] != nil }
    .map { g in
      Group(title: g.title, rows: g.rows.filter { topPicks[g.title]?.contains($0.key) == true })
    }

  /// 全ショートカット件数（サイドバー「すべて」の件数）。
  static let totalCount = all.reduce(0) { $0 + $1.rows.count }

  /// キーボード物理配列の 1 キー。`width` は 1 単位（U）に対する倍率。
  struct Key {
    let id: String
    let width: CGFloat
    let label: String

    init(_ id: String, _ width: CGFloat = 1, _ label: String? = nil) {
      self.id = id
      self.width = width
      self.label = label ?? id.uppercased()
    }
  }

  /// キーボード物理 6 段配列（デザイン見本の KB をそのまま移植）。
  static let keyboard: [[Key]] = [
    [
      Key("esc", 1.5, "esc"), Key("f1", 1.125, "F1"), Key("f2", 1.125, "F2"),
      Key("f3", 1.125, "F3"), Key("f4", 1.125, "F4"), Key("f5", 1.125, "F5"),
      Key("f6", 1.125, "F6"), Key("f7", 1.125, "F7"), Key("f8", 1.125, "F8"),
      Key("f9", 1.125, "F9"), Key("f10", 1.125, "F10"), Key("f11", 1.125, "F11"),
      Key("f12", 1.125, "F12"),
    ],
    [
      Key("`"), Key("1"), Key("2"), Key("3"), Key("4"), Key("5"), Key("6"), Key("7"),
      Key("8"), Key("9"), Key("0"), Key("-"), Key("="), Key("delete", 2, "⌫"),
    ],
    [
      Key("tab", 1.5, "⇥"), Key("q"), Key("w"), Key("e"), Key("r"), Key("t"), Key("y"),
      Key("u"), Key("i"), Key("o"), Key("p"), Key("["), Key("]"), Key("\\", 1.5, "\\"),
    ],
    [
      Key("caps", 1.75, "⇪"), Key("a"), Key("s"), Key("d"), Key("f"), Key("g"), Key("h"),
      Key("j"), Key("k"), Key("l"), Key(";"), Key("'"), Key("return", 2.25, "⏎"),
    ],
    [
      Key("shift", 2.25, "⇧"), Key("z"), Key("x"), Key("c"), Key("v"), Key("b"), Key("n"),
      Key("m"), Key(","), Key("."), Key("/"), Key("rshift", 2.75, "⇧"),
    ],
    [
      Key("fn", 1, "fn"), Key("ctrl", 1, "⌃"), Key("opt", 1, "⌥"), Key("cmd", 1.25, "⌘"),
      Key("space", 5.5, ""), Key("rcmd", 1.25, "⌘"), Key("ropt", 1, "⌥"),
      Key("left", 1, "◀"), Key("ud", 1, "▲\n▼"), Key("right", 1, "▶"),
    ],
  ]

  /// 下寄せラベルで描く修飾キー id（デザイン見本 MOD_RE の集合表現）。
  static let modifierKeys: Set<String> = [
    "shift", "rshift", "caps", "tab", "return", "delete",
    "cmd", "rcmd", "opt", "ropt", "ctrl", "fn",
  ]

  /// combo id → 表示記号（キー絞り込みチップ用）。無ければ id の大文字。
  static let symbols: [String: String] = [
    "cmd": "⌘", "shift": "⇧", "ctrl": "⌃", "opt": "⌥", "tab": "⇥", "return": "⏎",
    "esc": "esc", "space": "space", "delete": "⌫",
    "left": "◀", "right": "▶", "ud": "▲▼",
  ]

  /// combo id のチップ表示（記号があれば記号、無ければ大文字）。
  static func symbol(for id: String) -> String {
    symbols[id] ?? id.uppercased()
  }

  /// ショートカットに登場するキーの集合（キーボード可視化の明暗・クリック可否に使う）。
  static let usedKeys: Set<String> = Set(all.flatMap { $0.rows.flatMap(\.combo) })
}
