import AppKit

/// Orbe（chrome）が先取りするキー操作。surface へは転送しない。
/// mac 慣習ベースのキュレート既定の単一ソース。
enum ChromeAction {
  case increaseFontSize
  case decreaseFontSize
  case resetFontSize
  case closeTab
  case newTab
  case showClosedAgentsPalette  // 閉じたエージェント パレットを開く
  case nextTab
  case prevTab
  case find  // スクロールバック検索バーを開く
  case switchWorkspace  // workspace コマンドパレットを開く
  case launchDefaultAgent  // デフォルトエージェントを新タブで起動
  case showAgentPalette  // エージェント起動パレットを開く
  case showDispatchPalette  // Dispatch パレット（worktree/branch/issue/PR から起動）を開く
  case openEditor  // アクティブタブの cwd を GUI エディタで開く
  case rename  // フォーカス中タブをリネーム
  case showSettings  // 設定パレットを開く
  case scrollToTop  // スクロールバック先頭へジャンプ
  case scrollToBottom  // スクロールバック末尾へジャンプ
  case toggleHelp  // ヘルプオーバーレイ（ショートカットチートシート）をトグル開閉
  case toggleEditorFace  // エディター面 ⇄ 端末面（分割中は焦点の往復）
  case saveDocument  // エディター焦点の文書を保存
}

/// 面（surface・エディター pane）から届く、ウィンドウレベルの chrome 操作（タブ・workspace）。
enum WindowCommand {
  case newTab
  case closeTab
  case showClosedAgentsPalette
  case nextTab
  case prevTab
  case switchWorkspace
  case launchDefaultAgent
  case showAgentPalette
  case showDispatchPalette
  case openEditor
  case renameTab
  case showSettings
  case toggleHelp
  case toggleEditorFace
}

extension ChromeAction {
  /// WindowController へ届く window コマンドへの写像。surface ローカル操作は nil。
  /// 面の経路（`SurfaceView.perform`・`EditorPaneView.keyDown`）と window レベル経路
  /// （`ChromeHostingView`）が共有する単一ソース mapping（網羅 switch）。
  var windowCommand: WindowCommand? {
    switch self {
    case .newTab: return .newTab
    case .closeTab: return .closeTab
    case .showClosedAgentsPalette: return .showClosedAgentsPalette
    case .nextTab: return .nextTab
    case .prevTab: return .prevTab
    case .switchWorkspace: return .switchWorkspace
    case .launchDefaultAgent: return .launchDefaultAgent
    case .showAgentPalette: return .showAgentPalette
    case .showDispatchPalette: return .showDispatchPalette
    case .openEditor: return .openEditor
    case .rename: return .renameTab
    case .showSettings: return .showSettings
    case .toggleHelp: return .toggleHelp
    case .toggleEditorFace: return .toggleEditorFace
    case .increaseFontSize, .decreaseFontSize, .resetFontSize, .find,
      .scrollToTop, .scrollToBottom, .saveDocument:
      return nil
    }
  }

  /// キーを所有する面。window コマンドは面を問わず上位へ、端末のキーはエディター焦点中に消え、
  /// エディターのキーは端末焦点中に端末へ素通しし、両面のキーは焦点の面がそれぞれの意味で扱う。
  enum Owner {
    case window
    case terminal
    case editor
    case eachFace
  }

  /// 網羅 switch（default 無し）＝新ケース追加時に所有面の分類をコンパイルで求める。
  var owner: Owner {
    switch self {
    case .newTab, .closeTab, .showClosedAgentsPalette, .nextTab, .prevTab, .switchWorkspace,
      .launchDefaultAgent, .showAgentPalette, .showDispatchPalette, .openEditor, .rename,
      .showSettings, .toggleHelp, .toggleEditorFace:
      return .window
    case .increaseFontSize, .decreaseFontSize, .resetFontSize, .find:
      return .terminal
    case .saveDocument:
      return .editor
    case .scrollToTop, .scrollToBottom:
      return .eachFace
    }
  }
}

extension WindowCommand {
  /// タブが無くても意味を持ち安全に実行できる window コマンドか。
  /// true のものだけを window レベル（`ChromeHostingView.performKeyEquivalent`）で0タブでも配信する。
  /// 網羅 switch（default 無し）＝新ケース追加時に分類漏れをコンパイルエラーで検出する。
  var availableWithoutTabs: Bool {
    switch self {
    case .newTab, .showClosedAgentsPalette, .switchWorkspace,
      .launchDefaultAgent, .showAgentPalette, .showDispatchPalette, .showSettings, .toggleHelp:
      return true
    case .nextTab, .prevTab, .openEditor, .renameTab, .closeTab, .toggleEditorFace:
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
    case "e": return .toggleEditorFace  // Cmd+E
    case "f": return .find  // Cmd+F
    case "r": return .rename  // Cmd+R
    case "s": return .saveDocument  // Cmd+S
    case "w": return .closeTab  // Cmd+W
    case "t": return .newTab  // Cmd+T
    case "T": return .showClosedAgentsPalette  // Cmd+Shift+T
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
