import SwiftUI

/// SwiftUI 向けトークンの窓口。値の正（SSOT）は `Theme`（NSColor/NSFont）。
/// - AppKit: `Theme.Color.x` / `Theme.Typography.x`
/// - SwiftUI: `Color.theme.x` / `Font.theme.x`
/// 余白・角丸・線は CGFloat なので `Theme.Space.bar` 等をそのまま使う。
extension Color {
  static let theme = ThemeColors()
}

/// `Theme.Color`(NSColor) を SwiftUI `Color` に橋渡ししたミラー。動的（dark/light）は維持される。
struct ThemeColors {
  // 背景・面
  let bgBase = Color(nsColor: Theme.Color.bgBase)
  let bgSunken = Color(nsColor: Theme.Color.bgSunken)
  let bgDeepest = Color(nsColor: Theme.Color.bgDeepest)
  let surface0 = Color(nsColor: Theme.Color.surface0)
  let surface1 = Color(nsColor: Theme.Color.surface1)
  let surface2 = Color(nsColor: Theme.Color.surface2)
  let createDashBorder = Color(nsColor: Theme.Color.createDashBorder)
  // テキスト階層
  let textPrimary = Color(nsColor: Theme.Color.textPrimary)
  let textSecondary = Color(nsColor: Theme.Color.textSecondary)
  let textTertiary = Color(nsColor: Theme.Color.textTertiary)
  let textMuted = Color(nsColor: Theme.Color.textMuted)
  // アクセント
  let accentPrimary = Color(nsColor: Theme.Color.accentPrimary)
  let accentFocus = Color(nsColor: Theme.Color.accentFocus)
  let accentBright = Color(nsColor: Theme.Color.accentBright)
  let onAccent = Color(nsColor: Theme.Color.onAccent)
  // ブランドグリフ ◐ の紫グラデ（テーマ非依存・objectBoundingBox start (0,0) → end (0.6,1)）
  let glyphGradient = LinearGradient(
    colors: [
      Color(red: 0xb1 / 255, green: 0x8a / 255, blue: 0xff / 255),
      Color(red: 0x5b / 255, green: 0x34 / 255, blue: 0xc4 / 255),
    ],
    startPoint: UnitPoint(x: 0, y: 0), endPoint: UnitPoint(x: 0.6, y: 1))
  // diff / 成功・エラー・競合
  let diffAdded = Color(nsColor: Theme.Color.diffAdded)
  let diffRemoved = Color(nsColor: Theme.Color.diffRemoved)
  let success = Color(nsColor: Theme.Color.success)
  let danger = Color(nsColor: Theme.Color.danger)
  let conflict = Color(nsColor: Theme.Color.conflict)
  // エージェント状態（色は補強。一次情報はグリフ形＋動き）
  let stateWorking = Color(nsColor: Theme.Color.stateWorking)
  let stateWaiting = Color(nsColor: Theme.Color.stateWaiting)
  let stateDone = Color(nsColor: Theme.Color.stateDone)
  let stateIdle = Color(nsColor: Theme.Color.stateIdle)
  let stateDormant = Color(nsColor: Theme.Color.stateDormant)
  // 反転面（選択タブ）上の状態色＝対テーマの状態色
  let stateWorkingInverse = Color(nsColor: Theme.Color.stateWorkingInverse)
  let stateWaitingInverse = Color(nsColor: Theme.Color.stateWaitingInverse)
  let stateDoneInverse = Color(nsColor: Theme.Color.stateDoneInverse)
  // ステータスストリップ・done グリフ
  let statusText = Color(nsColor: Theme.Color.statusText)
  let checkStroke = Color(nsColor: Theme.Color.checkStroke)
  // ヘルプのキーボード可視化（使用キー / 未使用キーの文字色）
  let kbKeyText = Color(nsColor: Theme.Color.kbKeyText)
  let kbKeyMutedText = Color(nsColor: Theme.Color.kbKeyMutedText)
  // セグメント形タブバー
  let tabRowBg = Color(nsColor: Theme.Color.tabRowBg)
  let tabSegBg = Color(nsColor: Theme.Color.tabSegBg)
  let tabActiveText = Color(nsColor: Theme.Color.tabActiveText)
  // 状態の塗り（事前 alpha 済み）
  let selectionFill = Color(nsColor: Theme.Color.selectionFill)
  let diffSelectionFill = Color(nsColor: Theme.Color.diffSelectionFill)
  let hoverFill = Color(nsColor: Theme.Color.hoverFill)
  let smallPillFill = Color(nsColor: Theme.Color.smallPillFill)
  // 状態別 tint
  let tintWorking = Color(nsColor: Theme.Color.tintWorking)
  let tintWaiting = Color(nsColor: Theme.Color.tintWaiting)
  let tintDone = Color(nsColor: Theme.Color.tintDone)
  let tintRed = Color(nsColor: Theme.Color.tintRed)
  // オーバーレイ暗幕
  let scrim = Color(nsColor: Theme.Color.scrim)
  let scrimStrong = Color(nsColor: Theme.Color.scrimStrong)
  // EditorPane（基色 ink はフルアルファ。view 側で .opacity(α) を掛けて実際の面色にする）
  let surfaceInk = Color(nsColor: Theme.Color.surfaceInk)
  let borderInk = Color(nsColor: Theme.Color.borderInk)
  let paneWash = Color(nsColor: Theme.Color.paneWash)
  let inputWash = Color(nsColor: Theme.Color.inputWash)
  let inputBorder = Color(nsColor: Theme.Color.inputBorder)
  let tintAccent = Color(nsColor: Theme.Color.tintAccent)
  let promptGreen = Color(nsColor: Theme.Color.promptGreen)
}

extension Font {
  static let theme = ThemeFonts()
}

/// `Theme.Typography`(NSFont) を SwiftUI `Font` に橋渡ししたミラー。
struct ThemeFonts {
  let title = Font(Theme.Typography.title as CTFont)
  let label = Font(Theme.Typography.label as CTFont)
  let labelStrong = Font(Theme.Typography.labelStrong as CTFont)
  let body = Font(Theme.Typography.body as CTFont)
  let code = Font(Theme.Typography.code as CTFont)
  let chrome = Font(Theme.Typography.chrome as CTFont)
  let workspaceName = Font(Theme.Typography.workspaceName as CTFont)
  let diffHeader = Font(Theme.Typography.diffHeader as CTFont)
  let diffStat = Font(Theme.Typography.diffStat as CTFont)
  let codeSmall = Font(Theme.Typography.codeSmall as CTFont)
  let codeCompact = Font(Theme.Typography.codeCompact as CTFont)
  let bodySmall = Font(Theme.Typography.bodySmall as CTFont)
  let caption = Font(Theme.Typography.caption as CTFont)
  let captionDigit = Font(Theme.Typography.captionDigit as CTFont)
  let meta = Font(Theme.Typography.meta as CTFont)
  let sectionLabel = Font(Theme.Typography.sectionLabel as CTFont)
  let display = Font(Theme.Typography.display as CTFont)
  // EditorPane
  let paneRow = Font(Theme.Typography.paneRow as CTFont)
  let paneControl = Font(Theme.Typography.paneControl as CTFont)
  let paneAnnotation = Font(Theme.Typography.paneAnnotation as CTFont)
  let paneSegment = Font(Theme.Typography.paneSegment as CTFont)
  let paneFootnote = Font(Theme.Typography.paneFootnote as CTFont)
  let paneBadge = Font(Theme.Typography.paneBadge as CTFont)
  let paneTag = Font(Theme.Typography.paneTag as CTFont)
  // Help（⌘H チートシート）
  let helpTitle = Font(Theme.Typography.helpTitle as CTFont)
  let helpRow = Font(Theme.Typography.helpRow as CTFont)
  let helpSidebarItem = Font(Theme.Typography.helpSidebarItem as CTFont)
  let helpKeyList = Font(Theme.Typography.helpKeyList as CTFont)
  let helpCount = Font(Theme.Typography.helpCount as CTFont)
  let helpSection = Font(Theme.Typography.helpSection as CTFont)
  let helpCaption = Font(Theme.Typography.helpCaption as CTFont)
  let helpKeyFn = Font(Theme.Typography.helpKeyFn as CTFont)
  let helpKeyArrow = Font(Theme.Typography.helpKeyArrow as CTFont)
  let proseBody = Font(Theme.Typography.proseBody as CTFont)
  let proseHeading = Font(Theme.Typography.proseHeading as CTFont)
  let proseTitle = Font(Theme.Typography.proseTitle as CTFont)
}
