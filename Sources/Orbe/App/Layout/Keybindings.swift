import AppKit

/// Orbe（chrome）が先取りするキー操作。surface へは転送しない。
/// mac 慣習ベースのキュレート既定の単一ソース。
enum ChromeAction {
  case increaseFontSize
  case decreaseFontSize
  case resetFontSize
  case closeTab
  case showClosedAgentsPalette  // 閉じたエージェント パレットを開く
  case nextTab
  case prevTab
  case find  // 検索（端末はスクロールバック・エディターはファイル内）
  case findInProject  // プロジェクト全体を検索（エディターの検索パネル）
  case switchWorkspace  // workspace コマンドパレットを開く
  case launchDefaultAgent  // デフォルトエージェントを新タブで起動
  case showAgentPalette  // エージェント起動パレットを開く
  case showWorktreePalette  // worktree パレット（worktree・ブランチを選んで新しいタブを開く）を開く
  case showTaskPalette  // タスク画面を開く
  case openEditor  // アクティブタブの cwd を GUI エディタで開く
  case rename  // フォーカス中タブをリネーム
  case showSettings  // 設定パレットを開く
  case scrollToTop  // スクロールバック先頭へジャンプ
  case scrollToBottom  // スクロールバック末尾へジャンプ
  case toggleHelp  // ヘルプオーバーレイ（ショートカットチートシート）をトグル開閉
  case toggleEditorFace  // エディターを開く・閉じる
  case toggleBrowser  // 内蔵ブラウザを開く・閉じる
  case saveDocument  // エディター焦点の文書を保存
  case toggleEditorSidebar  // エディターの左の列（ツリー）を開く・閉じる
  case toggleEditorItemList  // エディターの上のバーの今の項目の一覧を開く・閉じる
}

/// 面（surface・エディター pane・ブラウザ層）から届く、ウィンドウレベルの chrome 操作（タブ・workspace）。
enum WindowCommand {
  case closeTab
  case showClosedAgentsPalette
  case nextTab
  case prevTab
  case switchWorkspace
  case launchDefaultAgent
  case showAgentPalette
  case showWorktreePalette
  case showTaskPalette
  case openEditor
  case renameTab
  case showSettings
  case toggleHelp
  case toggleEditorFace
  case toggleBrowser
  case findInProject
}

/// ブラウザ層（Z=2）に焦点がある間のブラウザ固有キー操作。
enum BrowserKeyAction: Equatable {
  case newTab
  case closeTab
  case reload
  case reopenClosedTab
  case toggleSidebar
}

/// ブラウザ層（Z=2）に焦点がある間の `ChromeAction` 振り分け分類。
enum BrowserKeyRouting: Equatable {
  case browser(BrowserKeyAction)
  case window(WindowCommand)
  case block
  case passthrough
}

extension ChromeAction {
  /// ブラウザ焦点時の単一キー振り分け（default 無しの網羅 switch）。
  var browserRouting: BrowserKeyRouting {
    switch self {
    case .showWorktreePalette: return .browser(.newTab)
    case .closeTab: return .browser(.closeTab)
    case .rename: return .browser(.reload)
    case .showClosedAgentsPalette: return .browser(.reopenClosedTab)
    case .saveDocument: return .browser(.toggleSidebar)
    case .toggleBrowser: return .window(.toggleBrowser)
    case .toggleEditorFace: return .window(.toggleEditorFace)
    case .findInProject: return .window(.findInProject)
    case .openEditor: return .window(.openEditor)
    case .nextTab: return .window(.nextTab)
    case .prevTab: return .window(.prevTab)
    case .switchWorkspace: return .window(.switchWorkspace)
    case .launchDefaultAgent: return .window(.launchDefaultAgent)
    case .showAgentPalette: return .window(.showAgentPalette)
    case .showTaskPalette: return .window(.showTaskPalette)
    case .showSettings: return .window(.showSettings)
    case .toggleHelp: return .window(.toggleHelp)
    case .increaseFontSize, .decreaseFontSize, .resetFontSize,
      .toggleEditorSidebar, .toggleEditorItemList, .find:
      return .block
    case .scrollToTop, .scrollToBottom:
      return .passthrough
    }
  }

  /// WindowController へ届く window コマンドへの写像。surface ローカル操作は nil。
  /// 面の経路（`SurfaceView.perform`・`EditorPaneView.performKeyEquivalent`）と window レベル経路
  /// （`ChromeHostingView`）が共有する単一ソース mapping（網羅 switch）。
  var windowCommand: WindowCommand? {
    switch self {
    case .closeTab: return .closeTab
    case .showClosedAgentsPalette: return .showClosedAgentsPalette
    case .nextTab: return .nextTab
    case .prevTab: return .prevTab
    case .switchWorkspace: return .switchWorkspace
    case .launchDefaultAgent: return .launchDefaultAgent
    case .showAgentPalette: return .showAgentPalette
    case .showWorktreePalette: return .showWorktreePalette
    case .showTaskPalette: return .showTaskPalette
    case .openEditor: return .openEditor
    case .rename: return .renameTab
    case .showSettings: return .showSettings
    case .toggleHelp: return .toggleHelp
    case .toggleEditorFace: return .toggleEditorFace
    case .toggleBrowser: return .toggleBrowser
    case .findInProject: return .findInProject
    case .increaseFontSize, .decreaseFontSize, .resetFontSize, .find,
      .scrollToTop, .scrollToBottom, .saveDocument, .toggleEditorSidebar, .toggleEditorItemList:
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
    case .closeTab, .showClosedAgentsPalette, .nextTab, .prevTab, .switchWorkspace,
      .launchDefaultAgent, .showAgentPalette, .showWorktreePalette, .showTaskPalette, .openEditor,
      .rename, .showSettings, .toggleHelp, .toggleEditorFace, .toggleBrowser, .findInProject:
      return .window
    case .increaseFontSize, .decreaseFontSize, .resetFontSize:
      return .terminal
    case .saveDocument, .toggleEditorSidebar, .toggleEditorItemList:
      return .editor
    case .find, .scrollToTop, .scrollToBottom:
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
    case .showClosedAgentsPalette, .switchWorkspace,
      .launchDefaultAgent, .showAgentPalette, .showWorktreePalette, .showTaskPalette, .showSettings,
      .toggleHelp, .toggleBrowser:
      return true
    case .nextTab, .prevTab, .openEditor, .renameTab, .closeTab, .toggleEditorFace,
      .findInProject:
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
    case "F": return .findInProject  // Cmd+Shift+F
    case "r": return .rename  // Cmd+R
    case "s": return .saveDocument  // Cmd+S
    case "b": return .toggleBrowser  // Cmd+B
    case "B": return .toggleEditorSidebar  // Cmd+Shift+B
    case "p": return .toggleEditorItemList  // Cmd+P
    case "w": return .closeTab  // Cmd+W
    case "t": return .showWorktreePalette  // Cmd+T
    case "T": return .showClosedAgentsPalette  // Cmd+Shift+T
    case "}": return .nextTab  // Cmd+Shift+]
    case "{": return .prevTab  // Cmd+Shift+[
    case "S": return .switchWorkspace  // Cmd+Shift+S
    case "A": return .showAgentPalette  // Cmd+Shift+A
    case "C": return .launchDefaultAgent  // Cmd+Shift+C
    case "E": return .openEditor  // Cmd+Shift+E
    case "X": return .showTaskPalette  // Cmd+Shift+X
    case "h": return .toggleHelp  // Cmd+H（macOS Hide から奪取。メニューの Hide は無割当で残す）
    default: return nil
    }
  }
}
