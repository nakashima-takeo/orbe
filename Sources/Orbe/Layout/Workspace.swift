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
  /// このセッションで一度でもアクティブになった（タブをウィンドウへ乗せ surface を起こした）か。
  /// 復元直後の未切替 workspace は false（＝休眠）。永続化しない（次回起動でまた休眠から始まる）。
  var activated = false
  /// この workspace に最後に切り替えてフォーカスした時刻（MRU 並べ替えのキー）。永続化する。
  /// 旧データ・未使用は nil（並べ替えで最古扱い）。
  var lastUsedAt: Date?
  /// この workspace の設定上書き層（全設定を上書き可）。nil＝上書き無し（global 継承）。永続化する。
  var settingsOverride: SettingsLayer?

  init(name: String, rootPath: String) {
    self.name = name
    self.rootPath = rootPath
  }
}
