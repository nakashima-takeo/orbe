import Foundation

/// zsh 補完の ZDOTDIR interposition。`.app` 同梱の shim dir（`Resources/zsh/`）へ GUI プロセスの
/// ZDOTDIR を向け、Orbe が起こした zsh に shim（ユーザー設定へのブリッジ＋widget source）を読ませる。
/// ユーザーのファイルには一切書き込まない。
enum CompletionShim {
  /// Orbe の shim dir か。本番 / Dev / 旧版を問わず `orbe-completion.zsh` を持つ dir がそれで、
  /// shim（`.zshenv`）も同じ述語で自分の同類を見分ける。
  static func isShimDirectory(_ path: String) -> Bool {
    FileManager.default.isReadableFile(
      atPath: URL(fileURLWithPath: path).appendingPathComponent("orbe-completion.zsh").path)
  }

  /// 同梱 shim dir（`<bundle>/Contents/Resources/zsh`）。`swift run`（バンドル無し）では nil。
  /// zsh の入口 `.zshenv` があり、かつ `isShimDirectory` を満たすときだけ据える——据えた dir は
  /// 必ず shim 自身・別インスタンスの `activate()` から Orbe の shim dir と認識される。
  static var directoryPath: String? {
    guard let resources = BundledResources.root else { return nil }
    let dir = resources.appendingPathComponent("zsh")
    let hasEntry = FileManager.default.isReadableFile(
      atPath: dir.appendingPathComponent(".zshenv").path)
    return hasEntry && isShimDirectory(dir.path) ? dir.path : nil
  }

  /// env から見たユーザーの ZDOTDIR。`ZDOTDIR` → `ORBE_USER_ZDOTDIR` の順で、空でなく Orbe の
  /// shim dir でない最初の値。親 Orbe・汚染シェルから継いだ shim dir・空文字はユーザー値ではない。
  static func userZdotdir(
    in env: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    for key in ["ZDOTDIR", "ORBE_USER_ZDOTDIR"] {
      if let value = env[key], !value.isEmpty, !isShimDirectory(value) { return value }
    }
    return nil
  }

  /// GUI プロセス env に shim を据える。surface spawn の base env は GUI プロセス env そのもの
  /// （ghostty defaultTermioEnv）なので、ghostty setupZsh がこれを「ユーザーの ZDOTDIR」として
  /// GHOSTTY_ZSH_ZDOTDIR へ退避し自然連鎖する。surface config の env_vars は shell integration
  /// setup の後勝ちで ghostty の ZDOTDIR を壊すため使えない（注入点はプロセス env が唯一正しい）。
  /// `ORBE_USER_ZDOTDIR` はここが完全に所有する——ユーザー値があれば据え、無ければ消す。
  /// 以降 GUI プロセス env の `ORBE_USER_ZDOTDIR` は「存在すれば必ず正当なユーザー値」と読める。
  /// Ghostty 初期化前に一度だけ呼ぶ。
  static func activate() {
    guard let dir = directoryPath else { return }
    if let user = userZdotdir() {
      setenv("ORBE_USER_ZDOTDIR", user, 1)
    } else {
      unsetenv("ORBE_USER_ZDOTDIR")
    }
    setenv("ZDOTDIR", dir, 1)
  }
}
