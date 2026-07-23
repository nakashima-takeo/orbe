import Foundation

/// ユーザー設定でない内部簿記（アプリ状態）の永続表現。settings.json から分離した `app-state.json` の中身。
/// 全 field Optional の家風（欠落・後方互換を壊さず読む）。
struct AppStateFile: Codable, Equatable {
  /// 状態追跡プラグインを各 CLI へ導入済みか。nil/false なら起動時に一度だけ導入を試みる。
  var agentPluginsInstalled: Bool?
  /// 旧 managed block 方式の導入済み flag。読み取りは legacy 掃除（除去して nil へ戻す）のみで、
  /// 新規に true を書く者はいない。
  var completionInstalled: Bool?
  /// ログインシェル PATH のディスクキャッシュ。起動復元の resume が同期で読む（subprocess を避ける）。
  var cachedShellPath: String?
  /// UI 言語（"ja"/"en"）。**nil = 未選択**（初回言語選択画面を出す・描画は OS 言語に追従）、
  /// 非 nil = 確定（その言語で起動し言語画面はスキップ）。設定パレットの言語行が書き替える。
  var preferredLanguage: String?
}

/// `app-state.json` のディスク永続（settings.json と並ぶ）。`StateDir.base()/app-state.json`。
enum AppStatePersistence {
  /// テスト用に保存先を差し替える（settings.json と対の seam）。本番は nil。
  static var fileURLOverride: URL?

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("app-state.json")
  }

  /// 読み込み。欠落・壊れは nil（呼び出し側が既定で fallback）。
  static func load() -> AppStateFile? {
    guard let url = fileURL, let data = try? Data(contentsOf: url),
      let file = try? JSONDecoder().decode(AppStateFile.self, from: data)
    else { return nil }
    return file
  }

  static func save(_ file: AppStateFile) {
    guard let url = fileURL else { return }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(file) else { return }
    try? data.write(to: url, options: .atomic)
  }

  /// 既存を読んで 1 field 変えて書き戻す（散在する内部簿記の書込点が共有する）。
  static func update(_ mutate: (inout AppStateFile) -> Void) {
    var file = load() ?? AppStateFile()
    mutate(&file)
    save(file)
  }
}
