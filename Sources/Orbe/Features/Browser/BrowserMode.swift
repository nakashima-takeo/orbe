import Foundation

/// 内蔵ブラウザ層（Z=2）の表示形態。ウィンドウに 1 つ持ち、workspace 切替をまたいで保持する。
enum BrowserMode: Equatable {
  case closed
  case sheet
  case full

  var isOpen: Bool { self != .closed }
}

/// 全面ブラウザ表示中の `⌥` 長押し（Peek）でツールバーに示す、直下の層の種別。
enum BrowserPeekUnderlay: Equatable {
  case terminal
  case editor
  case board
  case window

  var labelKey: L10nKey {
    switch self {
    case .terminal: .browserPeekShowTerminal
    case .editor: .browserPeekShowEditor
    case .board: .browserPeekShowBoard
    case .window: .browserPeekShowWindow
    }
  }
}
