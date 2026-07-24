import AppKit

/// Orbe（chrome）が先取りするキー操作。surface へは転送しない。
/// mac 慣習ベースのキュレート既定の単一ソース。
enum ChromeAction {
  case increaseFontSize
  case decreaseFontSize
  case resetFontSize
  case splitRight  // 縦線で左右に分割
  case splitDown  // 横線で上下に分割
  case closePane
  case newTab
  case nextTab
  case prevTab
  case prevTool  // Cmd+Shift+↑（上のツールへ）
  case nextTool  // Cmd+Shift+↓（下のツールへ）
  case find  // スクロールバック検索バーを開く
  case switchWorkspace  // workspace コマンドパレットを開く
  case newWorkspace  // ワークスペース作成フォームを開く
  case toggleEditorPane  // エディタペイン（Git ワークベンチ）の表示切替
  case launchDefaultAgent  // デフォルトエージェントを新タブで起動
  case showAgentPalette  // エージェント起動パレットを開く
  case showDispatchPalette  // Dispatch パレット（worktree/branch/issue/PR から起動）を開く
  case openEditor  // アクティブペインの cwd を GUI エディタで開く
  case rename  // フォーカス中タブをリネーム
  case showSettings  // 設定パレットを開く
  case scrollToTop  // スクロールバック先頭へジャンプ
  case scrollToBottom  // スクロールバック末尾へジャンプ
  case toggleHelp  // ヘルプオーバーレイ（ショートカットチートシート）をトグル開閉
}

extension ChromeAction {
  /// WindowController へ届く window コマンドへの写像。surface ローカル操作は nil。
  /// surface 経路（`SurfaceView.perform`）と window レベル経路（`ChromeHostingView`）が
  /// 共有する単一ソース mapping（網羅 switch）。
  var windowCommand: TerminalController.WindowCommand? {
    switch self {
    case .newTab: return .newTab
    case .nextTab: return .nextTab
    case .prevTab: return .prevTab
    case .prevTool: return .prevTool
    case .nextTool: return .nextTool
    case .switchWorkspace: return .switchWorkspace
    case .newWorkspace: return .newWorkspace
    case .toggleEditorPane: return .toggleEditorPane
    case .launchDefaultAgent: return .launchDefaultAgent
    case .showAgentPalette: return .showAgentPalette
    case .showDispatchPalette: return .showDispatchPalette
    case .openEditor: return .openEditor
    case .rename: return .renameTab
    case .showSettings: return .showSettings
    case .toggleHelp: return .toggleHelp
    case .increaseFontSize, .decreaseFontSize, .resetFontSize,
      .splitRight, .splitDown, .closePane, .find,
      .scrollToTop, .scrollToBottom:
      return nil
    }
  }
}

extension TerminalController.WindowCommand {
  /// タブ/ペインが無くても意味を持ち安全に実行できる window コマンドか。
  /// true のものだけを window レベル（`ChromeHostingView.performKeyEquivalent`）で0タブでも配信する。
  /// 網羅 switch（default 無し）＝新ケース追加時に分類漏れをコンパイルエラーで検出する。
  var availableWithoutTabs: Bool {
    switch self {
    case .newTab, .newWorkspace, .switchWorkspace,
      .launchDefaultAgent, .showAgentPalette, .showDispatchPalette, .showSettings, .toggleHelp:
      return true
    case .nextTab, .prevTab, .prevTool, .nextTool,
      .toggleEditorPane, .openEditor, .renameTab:
      return false
    }
  }
}

enum Keybindings {
  static func chromeAction(for event: NSEvent) -> ChromeAction? {
    // 対象は Cmd（＋Shift）のみ。charactersIgnoringModifiers は Shift 以外の修飾を無視するため、
    // Opt/Ctrl 併用をここで弾かないと surface 側に届くべき super+alt 系の keybind を奪ってしまう。
    let flags = event.modifierFlags
    guard flags.contains(.command), flags.isDisjoint(with: [.option, .control]) else { return nil }
    // 矢印は Shift 有無で文字が変わらず文字 switch で次/前を分けられないため specialKey で判定。
    // Shift 必須にして Cmd+←/→（行頭・行末移動）は surface へ通す。
    if flags.contains(.shift) {
      switch event.specialKey {
      case .rightArrow: return .nextTab  // Cmd+Shift+→
      case .leftArrow: return .prevTab  // Cmd+Shift+←
      case .upArrow: return .prevTool  // Cmd+Shift+↑
      case .downArrow: return .nextTool  // Cmd+Shift+↓
      default: break
      }
    } else {
      switch event.specialKey {
      case .upArrow: return .scrollToTop  // Cmd+↑
      case .downArrow: return .scrollToBottom  // Cmd+↓
      default: break
      }
    }
    switch event.charactersIgnoringModifiers {
    case "=", "+": return .increaseFontSize
    case "-": return .decreaseFontSize
    case "0": return .resetFontSize
    case ",": return .showSettings  // Cmd+,
    case "f": return .find  // Cmd+F
    case "r": return .rename  // Cmd+R
    case "n": return .newWorkspace  // Cmd+N
    case "/": return .toggleEditorPane  // Cmd+/
    case "d": return .splitRight  // Cmd+D
    case "D": return .splitDown  // Cmd+Shift+D
    case "w": return .closePane  // Cmd+W
    case "t": return .newTab  // Cmd+T
    case "}": return .nextTab  // Cmd+Shift+]
    case "{": return .prevTab  // Cmd+Shift+[
    case "S": return .switchWorkspace  // Cmd+Shift+S
    case "A": return .showAgentPalette  // Cmd+Shift+A
    case "X": return .showDispatchPalette  // Cmd+Shift+X
    case "C": return .launchDefaultAgent  // Cmd+Shift+C
    case "E": return .openEditor  // Cmd+Shift+E
    case "h": return .toggleHelp  // Cmd+H（macOS Hide から奪取。メニューの Hide は無割当で残す）
    default: return nil
    }
  }
}
