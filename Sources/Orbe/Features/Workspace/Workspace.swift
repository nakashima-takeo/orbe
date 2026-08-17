import Foundation

/// 名前付きの、プロジェクト/文脈レベルのコンテナ。
/// root path（拠点）を持ち、複数タブ（TerminalController）を束ねる。
/// 非アクティブな間も生存し続け、配下 surface は生きたまま（keep-alive）。
final class Workspace {
  /// 制御チャネルの宛先 ID。
  let id = IdGen.next()
  var name: String
  var rootPath: String
  var tabs: [TerminalController] = []
  var active = 0
  /// このセッションで一度でも前面化されたか、配下のタブで materialize が開始されたか。
  /// 1 タブでも activated なら true だが、true でも未activatedタブを含み得る。永続化しない。
  var activated = false
  /// この workspace に最後に切り替えてフォーカスした時刻（MRU 並べ替えのキー）。永続化する。
  /// 旧データ・未使用は nil（並べ替えで最古扱い）。
  var lastUsedAt: Date?
  /// この workspace の設定上書き層（全設定を上書き可）。nil＝上書き無し（global 継承）。永続化する。
  var settingsOverride: SettingsLayer?
  /// 人のジェスチャで閉じたエージェントタブの開き直しスタック（⇧⌘T）。末尾が直近＝LIFO。永続化しない
  /// （`WorkspaceState` に対応フィールドを持たない＝アプリ終了で忘れる）。workspace ごとに
  /// 独立し、この workspace が消えればスタックも一緒に消える。変異は SessionStore 経由。
  var closedAgentTabs: [ClosedAgentTab] = []

  init(name: String, rootPath: String) {
    self.name = name
    self.rootPath = rootPath
  }
}
