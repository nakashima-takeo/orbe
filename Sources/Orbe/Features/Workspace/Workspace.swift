import Foundation

/// 名前付きの、プロジェクト/文脈レベルのコンテナ。
/// root path（拠点）を持ち、複数タブ（TerminalTab）を束ねる。
/// 非アクティブな間も生存し続け、配下 surface は生きたまま（keep-alive）。
final class Workspace {
  /// 制御チャネルの宛先 ID。
  let id = IdGen.next()
  var name: String
  var rootPath: String
  /// 並びは「同じ `groupKey` のタブは配列上で必ず隣接する」不変条件を持ち、保証者は `SessionStore` だけ
  /// ——変異は SessionStore 経由（復元の組み立てだけは直接 append し、直後の `SessionStore.load` の
  /// 正規化を必ず通す）。
  var tabs: [TerminalTab] = []
  var active = 0
  /// 配下に materialize 開始済みのタブが 1 枚以上あるか。
  /// タブ状態から導出する現在値で、0タブまたは全タブ未activatedなら false。永続化しない。
  var activated: Bool { tabs.contains(where: \.activated) }
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
