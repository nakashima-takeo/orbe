import AppKit

/// Orbe デザインシステムのトークン（値の唯一の正＝SSOT）。
/// 思想と使い方は `docs/design-system.md`。コンポーネントはここの semantic 名だけを参照し、
/// 生 hex・`NSColor.systemXxx`・直書き `ofSize:` を使わない。
/// 外観は dark=温かい炭＋フロストガラス / light=藤紙。色は状態（確定配色の温度分け）と
/// 自分の出番（電紫 accent）のためだけ。ガラス質感・elevation・glow は `DesignTokens+Glass.swift` に委任。
enum Theme {

  // MARK: - Color（dark / light を外観で出し分け）
  // Orbe の配色は色階層が少なく、複数の semantic 名が同一値へ意図的に収束する（＝別名で表現）。

  enum Color {
    // 背景・面
    static let bgBase = dyn(
      light: OrbePalette.Chrome.backgroundLight,
      dark: OrbePalette.Chrome.backgroundDark)  // 不透明ベース（識別色 SSOT）
    static let bgSunken = dynA(light: 0x3a3151, lightA: 0.05, dark: 0xffffff, darkA: 0.03)
    static let bgDeepest = dynA(light: 0x3a3151, lightA: 0.04, dark: 0xffffff, darkA: 0.04)
    static let surface0 = bgSunken  // 面（bgSunken へ収束）
    static let surface1 = dynA(light: 0x6e5aaa, lightA: 0.12, dark: 0xc7b9eb, darkA: 0.08)  // 罫線・枠
    static let surface2 = dynA(light: 0x6e5aaa, lightA: 0.15, dark: 0xc7b9eb, darkA: 0.10)
    // 作成導線行の破線罫線（borderInk 基調・dark .18 / light .28＝surface2 より濃い罫線）
    static let createDashBorder = dynA(light: 0x6e5aaa, lightA: 0.28, dark: 0xc7b9eb, darkA: 0.18)

    // テキスト階層（Orbe は3段 → tertiary が muted へ収束）
    static let textPrimary = dyn(
      light: OrbePalette.Chrome.foregroundLight,
      dark: OrbePalette.Chrome.foregroundDark)  // 本文・選択ラベル・タブ反転面の地（SSOT）
    static let textSecondary = dyn(light: 0x5f5678, dark: 0xb8afc4)  // 通常ラベル・非選択タブ
    static let textMuted = dyn(light: 0x8d85a3, dark: 0x8b8397)  // 非アクティブ・補助・ヒント
    static let textTertiary = textMuted  // 三次（muted へ収束）

    // アクセント（Orbe は focus 専用色が無く accent へ収束）
    static let accentPrimary = dyn(
      light: OrbePalette.Chrome.accentLight,
      dark: OrbePalette.Chrome.accentDark)  // 選択・自分の出番・プロンプト（SSOT）
    static let accentFocus = accentPrimary  // フォーカス（accentPrimary へ収束）
    // accent の明色変種。tint(accent) 面上の強調文字（ヘルプの絞り込みチップ等）。
    // light は紙面で accent 自体のコントラストが十分なため accent と同値。
    static let accentBright = dyn(light: 0x6d43d8, dark: 0xb18aff)
    static let onAccent = dyn(
      light: OrbePalette.Chrome.backgroundLight,
      dark: OrbePalette.Chrome.backgroundDark)  // accent 塗り上のインク＝地色（SSOT）

    // diff / 成功・エラー・競合（Orbe は追加=green / 削除=red）
    static let diffAdded = dyn(
      light: OrbePalette.Chrome.greenLight,
      dark: OrbePalette.Chrome.greenDark)  // 追加（green・SSOT）
    static let diffRemoved = dyn(
      light: OrbePalette.Chrome.redLight,
      dark: OrbePalette.Chrome.redDark)  // 削除（red・SSOT）
    static let success = diffAdded  // 成功（green・diffAdded へ収束）
    static let danger = diffRemoved  // エラー（red・diffRemoved へ収束）
    static let conflict = dyn(
      light: OrbePalette.Chrome.yellowLight,
      dark: OrbePalette.Chrome.yellowDark)  // 競合＝注意色（黄・accent-2・SSOT）

    // エージェント状態（確定配色。色は補強・一次情報はグリフ形＋動き）。
    // 状態色は StateHue（本ファイル末尾 private）が唯一の起点。state / inverse / tint が共有する。
    static let stateWorking = dyn(light: StateHue.workingLight, dark: StateHue.workingDark)  // 青
    static let stateWaiting = dyn(light: StateHue.waitingLight, dark: StateHue.waitingDark)  // 黄
    static let stateDone = dyn(light: StateHue.doneLight, dark: StateHue.doneDark)  // 完了(緑)
    static let stateIdle = dyn(light: StateHue.idleLight, dark: StateHue.idleDark)
    static let stateDormant = textMuted  // 休眠（muted へ収束）

    // 反転面（選択タブ）上の状態色＝対テーマの状態色。
    // dark/light の値を入れ替えただけ。idle はタブに出ないため反転色を持たない。
    static let stateWorkingInverse = dyn(light: StateHue.workingDark, dark: StateHue.workingLight)
    static let stateWaitingInverse = dyn(light: StateHue.waitingDark, dark: StateHue.waitingLight)
    static let stateDoneInverse = dyn(light: StateHue.doneDark, dark: StateHue.doneLight)

    // ステータスストリップ（件数の文字）と done グリフ check 線色
    static let statusText = dyn(light: 0x4d4368, dark: 0xcdc7e2)
    static let checkStroke = dyn(light: 0xf3f0fa, dark: 0x0a0a0a)

    // ヘルプ（⌘H）キーボード可視化のキー文字色。使用キー＝secondary と muted の中点（藤系色相維持）、
    // 未使用キー＝dark は muted より沈め / light は紙面へ近づけて薄める（明暗はキー背景でも冗長化）。
    static let kbKeyText = dyn(light: 0x766e8d, dark: 0xa99fb8)
    static let kbKeyMutedText = dyn(light: 0xa49cb5, dark: 0x6f6880)

    // セグメント形タブバー（2段目）。選択セグメントの地は textPrimary（前景色反転）。
    static let tabRowBg = dynA(light: 0x3a3151, lightA: 0.08, dark: 0x000000, darkA: 0.28)
    static let tabSegBg = dynA(light: 0x3a3151, lightA: 0.06, dark: 0xffffff, darkA: 0.10)
    static let tabActiveText = dyn(light: 0xf3f0fa, dark: 0x171420)  // light は bgBase と別値

    // 状態の塗り（事前 alpha 済み・テーマごとの accent 基調へ α を掛けた合成値）
    static let selectionFill = dynA(
      light: OrbePalette.Chrome.accentLight, lightA: 0.14,
      dark: OrbePalette.Chrome.accentDark, darkA: 0.14)
    static let diffSelectionFill = dynA(
      light: OrbePalette.Chrome.accentLight, lightA: 0.10,
      dark: OrbePalette.Chrome.accentDark, darkA: 0.10)
    static let hoverFill = dynA(
      light: OrbePalette.Chrome.accentLight, lightA: 0.10,
      dark: OrbePalette.Chrome.accentDark, darkA: 0.10)
    static let smallPillFill = dynA(light: 0x3a3151, lightA: 0.06, dark: 0xffffff, darkA: 0.04)

    // 状態別 tint（バッジ等の淡塗り。各テーマの状態色の 12–14%。design-system §2 のミラー）
    static let tintWorking = dynA(
      light: StateHue.workingLight, lightA: 0.12, dark: StateHue.workingDark, darkA: 0.12)
    static let tintWaiting = dynA(
      light: StateHue.waitingLight, lightA: 0.12, dark: StateHue.waitingDark, darkA: 0.12)
    static let tintDone = dynA(
      light: StateHue.doneLight, lightA: 0.12, dark: StateHue.doneDark, darkA: 0.12)
    static let tintRed = dynA(
      light: OrbePalette.Chrome.redLight, lightA: 0.14,
      dark: OrbePalette.Chrome.redDark, darkA: 0.14)

    // オーバーレイ暗幕（色のみ。blur は Scrim が用途別に担う）
    static let scrim = dynA(light: 0x3a3151, lightA: 0.18, dark: 0x0a080e, darkA: 0.35)
    static let scrimStrong = dynA(light: 0x3a3151, lightA: 0.22, dark: 0x0a080e, darkA: 0.40)
    // ヘルプ（⌘H）の最暗幕。全画面チートシートは背後の情報を要さず、最も深く沈める。
    static let scrimHelp = dynA(light: 0x3a3151, lightA: 0.30, dark: 0x0a080e, darkA: 0.55)

    // EditorPane（Git ワークベンチ）。面と罫線をフルアルファの基色 2 本として持ち、
    // view 側が用途ごとの α を .opacity(α) で掛ける
    // （α の組み合わせが多く、1 値 1 トークンでは名前が増殖するため。基色が SSOT）。
    static let surfaceInk = dyn(light: 0x3a3151, dark: 0xffffff)  // ペイン面の基色
    static let borderInk = dyn(light: 0x6e5aaa, dark: 0xc7b9eb)  // ペイン罫線・枠の基色
    // ペイン地・入力欄地（最深色の淡い被せ）
    static let paneWash = dynA(light: 0x3a3151, lightA: 0.05, dark: 0x0a080e, darkA: 0.14)
    static let inputWash = dynA(light: 0x3a3151, lightA: 0.06, dark: 0x0a080e, darkA: 0.25)
    // 入力欄の枠（borderInk 基調・dark .12 / light .16＝surface1 より濃い）
    static let inputBorder = dynA(light: 0x6e5aaa, lightA: 0.16, dark: 0xc7b9eb, darkA: 0.12)
    // accent 12% の淡塗り（ブランチチップ）
    static let tintAccent = dynA(
      light: OrbePalette.Chrome.accentLight, lightA: 0.12,
      dark: OrbePalette.Chrome.accentDark, darkA: 0.12)
    static let promptGreen = diffAdded  // プロンプト・コマンド行（green・diffAdded へ収束）

    // MARK: 生成ヘルパ
    private static func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
      NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    private static func dyn(light: Int, dark: Int) -> NSColor {
      NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
      }
    }
    private static func dynA(light: Int, lightA: CGFloat, dark: Int, darkA: CGFloat) -> NSColor {
      NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark, darkA) : rgb(light, lightA)
      }
    }
  }

  // MARK: - Typography
  // UI・本文＝システムサンセリフ / ターミナル・ラベル・コード・ステータス語＝monospace。
  // 階層はサイズ＋色で。weight は見出し・選択の弁別に効く箇所だけ維持。

  enum Typography {
    static let title = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)  // パレットのクエリ・見出し
    static let label = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)  // パレット行・主ラベル
    static let labelStrong = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)  // 選択ラベル
    static let body = NSFont.systemFont(ofSize: 12.5, weight: .regular)  // 本文・プローズ
    static let code = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)  // コード・入力
    // TopBar・タブ・ストリップ
    static let chrome = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let workspaceName = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let diffHeader = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let diffStat = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let codeSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)  // 差分本文・パネル内
    static let codeCompact = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)  // 補完候補行
    static let bodySmall = NSFont.systemFont(ofSize: 10.5, weight: .regular)  // 小さな補助本文
    static let caption = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)  // 件数・小バッジ・小ボタン
    static let captionDigit = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)  // 件数
    static let meta = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)  // 行番号・メタ・ヒント
    static let sectionLabel = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)  // 大文字見出し
    static let display = NSFont.systemFont(ofSize: 26, weight: .regular)  // ページタイトル

    // EditorPane 専用の実寸タイポ（情報密度優先。汎用 type スケールの4段丸めには寄せない）
    // paneRow=レール行・本文行・チップ / paneControl=ヘッダ・ボタン・入力・履歴タイトル /
    // paneAnnotation=↑↓・hunk ヘッダ・注記 / paneSegment=セグメント・小ボタン・集計 /
    // paneFootnote=フッタ・stat・履歴サブ / paneBadge=CommitDetail のファイルバッジ /
    // paneTag=HEAD/ref/tag バッジ / prose*=md プレビュー（本文・H2+・H1）
    static let paneRow = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    static let paneControl = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let paneAnnotation = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    static let paneSegment = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    static let paneFootnote = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
    static let paneBadge = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    static let paneTag = NSFont.monospacedSystemFont(ofSize: 7.5, weight: .regular)

    // Help（⌘H チートシート）専用の実寸タイポ（デザイン px をそのまま pt に。
    // 11=chrome / 10=meta は既存トークンを再利用し、無いサイズだけ持つ）
    // helpTitle=見出し・検索・プロンプト / helpRow=行ラベル・凡例語 / helpSidebarItem=カテゴリ名 /
    // helpKeyList=一覧キーバッジ / helpCount=サイドバー件数 / helpSection=大文字見出し・フッター /
    // helpCaption=キーボード説明 / helpKeyFn=fn 行キー / helpKeyArrow=▲▼ キー
    static let helpTitle = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let helpRow = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let helpSidebarItem = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let helpKeyList = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    static let helpCount = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    static let helpSection = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    static let helpCaption = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
    static let helpKeyFn = NSFont.monospacedSystemFont(ofSize: 7.5, weight: .regular)
    static let helpKeyArrow = NSFont.monospacedSystemFont(ofSize: 6, weight: .regular)

    static let proseBody = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    static let proseHeading = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let proseTitle = NSFont.systemFont(ofSize: 17, weight: .bold)

    // tracking / line-height スカラ（NSFont では表せないため使用側で .tracking() / lineSpacing 換算）
    static let trackingLabel: CGFloat = 1  // 大文字セクション見出し
    static let trackingStatus: CGFloat = 0.3  // ステータスストリップ
    static let lineBody: CGFloat = 1.6  // 本文プローズ
    static let lineTerminal: CGFloat = 1.55  // ターミナル本文
    static let linePane: CGFloat = 1.7  // EditorPane の本文・diff 行送り
  }

  // MARK: - Opacity（fill 以外の状態。fill は Color.selectionFill/hoverFill）

  enum Opacity {
    static let dormant: CGFloat = 0.45  // 休眠（選択は可・減光）
    static let disabled: CGFloat = 0.45  // 操作不可
    static let pressed: CGFloat = 0.85  // 押下フィードバック
  }

  // MARK: - Spacing（2/4pt グリッド）

  enum Space {
    static let hair: CGFloat = 2
    static let tick: CGFloat = 4
    static let note: CGFloat = 6
    static let step: CGFloat = 8
    static let beat: CGFloat = 12
    static let bar: CGFloat = 16
    static let span: CGFloat = 20
    static let phrase: CGFloat = 24
  }

  // MARK: - Radius

  enum Radius {
    static let xs: CGFloat = 3  // タブセグメント
    static let sm: CGFloat = 4  // バッジ・キーヒント
    static let row: CGFloat = 8  // リスト行・小コントロール
    static let md: CGFloat = 10  // 入力・小パネル
    static let card: CGFloat = 12  // カード・設定行
    static let lg: CGFloat = 16  // パネル・オーバーレイ
    static let pill: CGFloat = 999  // カウントピル・トグル
  }

  // MARK: - Border / Ring

  enum Stroke {
    static let hairline: CGFloat = 1  // 罫線・枠
    static let marker: CGFloat = 3  // 引用・スパインの左バー
    static let focusRing: CGFloat = 2  // フォーカスリング（accentFocus）
  }

  // MARK: - Motion（値は秒 Double / offset は CGFloat）
  // ループ3種は Orbe の motion 正典。遷移4段＋easing は theme 中立の UI プリミティブ。

  enum Motion {
    static let instant: Double = 0  // アニメさせない
    static let quick: Double = 0.12  // hover・下線・リング
    static let base: Double = 0.18  // パネルのスライド
    static let slow: Double = 0.24  // バッジフェード
    // 標準イージング cubic-bezier(0.2,0,0,1)＝制御点 p1/p2（ease-out 寄り）
    static let easing: (p1: CGPoint, p2: CGPoint) = (CGPoint(x: 0.2, y: 0), CGPoint(x: 0, y: 1))

    static let spin: Double = 1.6  // working スピナー（linear infinite・rotate360）
    static let float: Double = 2.6  // waiting 浮遊（ease-in-out infinite）
    static let floatOffset: CGFloat = -1  // waiting translateY
    static let blink: Double = 1.1  // 点滅（0–55% 表示 / 56–100% 非表示）
  }
}

/// エージェント状態色の唯一の起点（chrome 専用・file-private）。
/// `Theme.Color` の state / stateInverse / tint がここから導出し、hex の三重複を防ぐ。
/// conflict（＝ANSI黄）・diffAdded（＝ANSI緑）とは別軸なので混ぜない（dark では waiting≠conflict / done≠diffAdd、light は同値だが別トークンとして分離保持）。
private enum StateHue {
  static let workingLight = 0x1f66c9
  static let workingDark = 0x85adff
  static let waitingLight = 0xb17b00
  static let waitingDark = 0xeec25a
  static let doneLight = 0x279a4d
  static let doneDark = 0x82d894
  static let idleLight = 0x8b82a8
  static let idleDark = 0x8a82b8
}
