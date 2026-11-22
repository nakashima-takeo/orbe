import Foundation

/// 骨（上のバー・左の列）の写し。pane が所有し、左の列の中身を画面から決めて写す。SwiftUI はこの写しと、件数・番号・
/// 開閉の持ち主だけを読み、`EditorSession` / `EditorDocument` を直接観測しない。操作は閉包で pane へ戻り、pane が連経由で
/// セッションに書く。
@MainActor @Observable
final class EditorShellModel {
  /// 左の列の中身。画面と、Files の左の列がエクスプローラーか検索かで決まる。
  enum Panel {
    case files
    case search
    case sourceControl
    case pullRequest

    /// 画面 `screen` の左の列の中身。Files の画面では `files`（エクスプローラーか検索）。
    init(screen: EditorScreen, files: Panel) {
      switch screen {
      case .files: self = files
      case .changes: self = .sourceControl
      case .pullRequest: self = .pullRequest
      }
    }

    /// この中身を出す画面。
    var screen: EditorScreen {
      switch self {
      case .files, .search: .files
      case .sourceControl: .changes
      case .pullRequest: .pullRequest
      }
    }
  }

  /// 左の列に出している中身（pane が画面から決めて写す）。
  var panel = Panel.files
  /// 器が透かしている（上のバーの「⌥ 端末を表示」を押している間の姿にする）。
  var isPeeking = false

  @ObservationIgnored var open: (URL, EditorSession.OpenMode) -> Void = { _, _ in }
  @ObservationIgnored var createFile: () -> Void = {}
  @ObservationIgnored var createDirectory: () -> Void = {}
  @ObservationIgnored var collapseAll: () -> Void = {}
  /// 上のバーで画面を選んだ。
  @ObservationIgnored var selectScreen: (EditorScreen) -> Void = { _ in }
  /// 上のバーの左端で左の列を開閉した。
  @ObservationIgnored var toggleSidebar: () -> Void = {}
  /// 行内入力の入力欄が焦点を失った（その世代）。別の view へ移ったなら pane が取り消し、窓へ落ちたなら
  /// pane が預かる。
  @ObservationIgnored var inlineInputLostFocus: (Int) -> Void = { _ in }
  /// 行内入力の行が現れた。焦点を取ってよいか（窓か面自身が持っているときだけ。人が別の view へ移していれば
  /// 奪わない）。
  @ObservationIgnored var inlineInputMayTakeFocus: () -> Bool = { true }
}
