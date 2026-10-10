import Foundation

/// 名前付きの、プロジェクト/文脈レベルのコンテナ。
/// root path（拠点）を持ち、複数タブ（TerminalTab）を束ねる。
/// 非アクティブな間も生存し続け、配下 surface は生きたまま（keep-alive）。
final class Workspace {
  /// 制御チャネルの宛先 ID。
  let id = IdGen.next()
  /// 起動をまたいで変わらない内部専用の ID。タスクが workspace を指すのに使い、外には見せない
  /// （外に見せるのは起動ごとの `id`）。改名・root の変更では変わらず、使い回さない。
  let persistentId: UUID
  var name: String
  var rootPath: String
  /// 並びは「同じ `groupKey` のタブは配列上で必ず隣接する」不変条件を持ち、保証者は `SessionStore` だけ
  /// ——変異は SessionStore 経由（復元の組み立てだけは直接 append し、直後の `SessionStore.load` の
  /// 正規化を必ず通す）。
  var tabs: [TerminalTab] = []
  /// 選んでいるもの。不変条件（`.tab` のタブは `tabs` にある・`.board` はボードを持つ workspace だけ・`.empty` はタブが 0 で
  /// ボードを持たないときだけ）の保証者は `SessionStore`。
  var selection: Selection = .empty
  /// 選んでいるタブ。ボード・空なら nil。
  var selectedTab: TerminalTab? {
    if case .tab(let tab) = selection { return tab }
    return nil
  }
  /// 選んでいるタブの位置。chrome・保存・制御 API へ位置で出すときだけ使う。
  var selectedTabIndex: Int? {
    selectedTab.flatMap { tab in tabs.firstIndex { $0 === tab } }
  }
  /// 配下に materialize 開始済みのタブが 1 枚以上あるか。
  /// タブ状態から導出する現在値で、0タブまたは全タブ未activatedなら false。永続化しない。
  var activated: Bool { tabs.contains(where: \.activated) }
  /// この workspace に最後に切り替えてフォーカスした時刻（MRU 並べ替えのキー）。永続化する。
  /// 旧データ・未使用は nil（並べ替えで最古扱い）。
  var lastUsedAt: Date?
  /// この workspace の設定上書き層（全設定を上書き可）。nil＝上書き無し（global 継承）。永続化する。
  var settingsOverride: SettingsLayer?
  /// worktree パレットで前回新しいブランチを作ったときのベース（ブランチ名）。次の作成行で最初に選ぶ。
  /// 書き手は起動時の復元と `WindowController.rememberWorktreeBase` だけ。永続化する。
  var lastWorktreeBase: String?

  /// workspace の選択。タブは位置ではなくタブそのもので指す（並びが変わっても同じタブを指し続ける）。
  enum Selection: Equatable {
    /// タブが 0 で、ボードも無い。
    case empty
    case board
    case tab(TerminalTab)

    static func == (a: Selection, b: Selection) -> Bool {
      switch (a, b) {
      case (.empty, .empty), (.board, .board): return true
      case (.tab(let x), .tab(let y)): return x === y
      default: return false
      }
    }
  }

  init(name: String, rootPath: String, persistentId: UUID = UUID()) {
    self.name = name
    self.rootPath = rootPath
    self.persistentId = persistentId
  }
}
