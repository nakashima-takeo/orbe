import Foundation

/// zsh 補完の ZDOTDIR interposition。`.app` 同梱の shim dir（`Resources/zsh/`）へ GUI プロセスの
/// ZDOTDIR を向け、Orbe が起こした zsh に shim（ユーザー設定へのブリッジ＋widget source）を読ませる。
/// ユーザーのファイルには一切書き込まない。
enum CompletionShim {
  /// 同梱 shim dir（`<bundle>/Contents/Resources/zsh`）。`swift run`（バンドル無し）では nil。
  static var directoryPath: String? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let dir = resources.appendingPathComponent("zsh")
    return FileManager.default.isReadableFile(atPath: dir.appendingPathComponent(".zshrc").path)
      ? dir.path : nil
  }

  /// GUI プロセス env に shim を据える。surface spawn の base env は GUI プロセス env そのもの
  /// （ghostty defaultTermioEnv）なので、ghostty setupZsh がこれを「ユーザーの ZDOTDIR」として
  /// GHOSTTY_ZSH_ZDOTDIR へ退避し自然連鎖する。surface config の env_vars は shell integration
  /// setup の後勝ちで ghostty の ZDOTDIR を壊すため使えない（注入点はプロセス env が唯一正しい）。
  /// Ghostty 初期化前に一度だけ呼ぶ。
  static func activate() {
    guard let dir = directoryPath else { return }
    if let user = ProcessInfo.processInfo.environment["ZDOTDIR"], !user.isEmpty {
      setenv("ORBE_USER_ZDOTDIR", user, 1)  // ターミナル起動・launchctl setenv 由来の実 ZDOTDIR を引き継ぐ
    }
    setenv("ZDOTDIR", dir, 1)
  }
}
