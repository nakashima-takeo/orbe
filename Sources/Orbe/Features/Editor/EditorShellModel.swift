import Foundation

/// 骨（上のバー・左の列）の写し。pane が所有し、セッションと文書から導いて書く。SwiftUI は `EditorSession` /
/// `EditorDocument` を直接観測せず、この写しか観測できる持ち主（ツリー・各パネルの状態・一覧の器・左の列の開閉）を読む。
/// 操作は閉包で pane へ戻り、pane が連経由でセッションに書く。
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

  /// 上のバーの今の項目——今の項目のボタンが示す対象。Files の画面で今の文書があるとき、そのファイル。Changes・PR の画面で
  /// 左の列を閉じていて、本体が diff のとき、その diff（差分のファイルの見出しの写しと同じ値）。
  enum CurrentItem: Equatable {
    case file(CurrentFile)
    case diff(DiffFileHeaderRoot.Subject)
  }

  /// 今の項目のファイルの写し（ボタンに出すもの）。
  struct CurrentFile: Equatable {
    let chip: FileChip
    /// 親のパス（根の下なら根からの相対のディレクトリに `/` を付けたもの。根の直下なら空。根の外なら `~` で縮めた絶対の
    /// ディレクトリ）。
    let directory: String
    let name: String
    let isPreview: Bool
    /// 印（無し・未保存・ディスクが変わった）。
    let mark: EditorItemListRow.Mark
    /// 「開いたままにする」にキーの札 ↵ を付けるか（仮の文書で、検索結果の列にフォーカスがある間——↵ が普通の文書として
    /// 開く操作になる、ただ 1 つの場所）。
    let showsKeepOpenKey: Bool
  }

  /// 左の列に出している中身（pane が画面から決めて写す）。
  var panel = Panel.files
  /// 器が透かしている（上のバーの「⌥ 端末を表示」を押している間の姿にする）。
  var isPeeking = false
  /// 本体の上端の帯（差分の見出し）の高さ。帯が無ければ 0。書くのは pane だけ（置き直すたびに）。置き場は、札を帯の下から
  /// 並べるために、これを読む。
  var bodyBandHeight: CGFloat = 0
  /// 今の項目（無ければボタンを出さない）。書くのは pane だけで、ボタンの表示・⌘P・一覧の器の開閉が同じ値を読む。
  var currentItem: CurrentItem?

  @ObservationIgnored var open: (URL, EditorSession.OpenMode) -> Void = { _, _ in }
  @ObservationIgnored var createFile: () -> Void = {}
  @ObservationIgnored var createDirectory: () -> Void = {}
  @ObservationIgnored var collapseAll: () -> Void = {}
  /// 上のバーで画面を選んだ。
  @ObservationIgnored var selectScreen: (EditorScreen) -> Void = { _ in }
  /// 上のバーの左端で左の列を開閉した。
  @ObservationIgnored var toggleSidebar: () -> Void = {}
  /// 上のバーの今の項目のボタンを押した。
  @ObservationIgnored var toggleItemList: () -> Void = {}
  /// 上のバーの「開いたままにする」を押した（今の仮の文書を普通の文書にする）。
  @ObservationIgnored var keepOpen: () -> Void = {}
  /// 今の項目のボタンの枠（バーの座標）が変わった。pane の幾何の入力で、写しには書かない。
  @ObservationIgnored var itemButtonFrameDidChange: (CGRect) -> Void = { _ in }
  /// 右端の主な操作のボタン（印）の枠（バーの座標）が変わった。ボタンが消えたら nil。pane の外の押下の判定の入力で、写しには
  /// 書かない。
  @ObservationIgnored var actionButtonFrameDidChange: (UUID, CGRect?) -> Void = { _, _ in }
  /// 行内入力の入力欄が焦点を失った（その世代）。別の view へ移ったなら pane が取り消し、窓へ落ちたなら
  /// pane が預かる。
  @ObservationIgnored var inlineInputLostFocus: (Int) -> Void = { _ in }
  /// 行内入力の行が現れた。焦点を取ってよいか（窓か面自身が持っているときだけ。人が別の view へ移していれば
  /// 奪わない）。
  @ObservationIgnored var inlineInputMayTakeFocus: () -> Bool = { true }
}
