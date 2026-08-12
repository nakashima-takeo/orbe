import Foundation

/// 起動経路の関門。`.app` の実行体を**コマンドとして直接叩かれた**起動を落とし、`orb` へ誘導する。
///
/// Orbe は CLI 引数を 1 つも解釈しない。libghostty は `--help` / `--version` を検出して内部に積むが、
/// それを実行する `ghostty_cli_try_action()` を Orbe は呼ばないため、**何を渡しても黙って GUI 起動へ
/// 素通りする**（出力ゼロのままウィンドウだけが増える）。素通り自体は無害に見えて、Orbe では
/// 二重起動に化ける——後発プロセスが control.sock を奪い、先発インスタンスが制御 API から
/// 永久に不達になる（→ [control/api](../../../docs/spec/control/api.md)）。
///
/// 直接 exec は事故として実在する。ghostty の shell integration がバンドルの `Contents/MacOS` を
/// ペインの PATH へ載せ、macOS の既定ファイルシステムは大小文字を区別しないため、`orb` の typo である
/// `orbe` が GUI 実行体そのものに解決する。しかも LaunchServices を経由しないので、macOS が普段
/// 面倒を見ている重複起動防止も効かない。制御 API はエージェントを第一級の利用者に据えており
/// （→ [control/api]）、`orb` を打たせる場面で typo が起きる前提で守る必要がある。
///
/// 判定は**引数の有無ではなく起動経路**で行う。LaunchServices（Finder / Dock / `open`）は Info.plist の
/// `LSEnvironment` 経由で `ORBE_LAUNCH_SOURCE` を注入するが、シェルからの直接 exec は Info.plist を
/// 一切見ないので注入されない。引数で判定すると LaunchServices / AppKit が渡す `-psn_` `-NS` 系を
/// 除外リストで追い続けることになり、しかも引数なしの `orbe`（typo の主形）を取り逃す。
enum LaunchGate {
  /// LaunchServices が `LSEnvironment`（`app/Info.plist`）経由で注入する起動経路の印。
  static let launchSourceEnvVar = "ORBE_LAUNCH_SOURCE"

  /// `LSEnvironment` に焼いてある値。これ以外（未設定含む）はすべて非 LaunchServices 起動と見なす。
  static let appLaunchSource = "app"

  enum Decision: Equatable {
    /// 通常の GUI 起動へ進む。
    case proceed
    /// コマンドとして叩かれた。`rejectionMessage` を stderr へ出して非 0 で終える。
    case reject
  }

  /// 起動経路の印を**読むと同時にプロセス env から落とす**。
  ///
  /// 読み取りと掃除を分けて書けない。ペインの env は spawn 時のプロセス env そのものなので、
  /// 落とし忘れるとペインがこの印を継承し、その中で打った `orbe` が「LaunchServices 経由の
  /// 正規起動」に見えて関門を素通りする。**判定器が最も要る現場——Orbe の中での typo——でだけ
  /// 壊れる**ため、Finder 起動でもターミナルからの直接 exec でも正しく動いてしまい、
  /// 通常の動作確認では露見しない。1 操作にまとめて忘れようがなくする。
  ///
  /// ghostty も同じ落とし穴を踏んで、子 env から `GHOSTTY_MAC_LAUNCH_SOURCE` を落としている
  /// （`vendor/ghostty/src/apprt/embedded.zig` の "Remove this so that running `ghostty` within
  /// Ghostty works."）。向き——ghostty は通したい / Orbe は落としたい——は逆だが、
  /// 「ターミナルの中で自分の名前が打たれる」ことへの備えは同じ。
  @discardableResult
  static func consumeLaunchSource() -> String? {
    let value = ProcessInfo.processInfo.environment[launchSourceEnvVar]
    unsetenv(launchSourceEnvVar)
    return value
  }

  /// 起動を通すか落とすか。観測済みの値だけで決まる純関数（判定規則をテストへ晒すための形）。
  ///
  /// - Parameters:
  ///   - isBundled: `.app` バンドルとして動いているか。`swift run`（バンドル無し）は開発起動で、
  ///     そもそも LaunchServices を通りようがないため無条件で通す。
  ///   - launchSource: `consumeLaunchSource()` の値。
  ///   - stateDir: `ORBE_STATE_DIR`。非空なら検証用の隔離インスタンス（sandbox-run）で、
  ///     直接 exec がその起こし方そのものなので通す。
  static func decide(isBundled: Bool, launchSource: String?, stateDir: String?) -> Decision {
    guard isBundled else { return .proceed }
    if launchSource == appLaunchSource { return .proceed }
    if let stateDir, !stateDir.isEmpty { return .proceed }
    return .reject
  }

  /// `reject` 時に stderr へ出す文言。`orb` の usage と同じ英語・小文字基調に揃える。
  ///
  /// 「起動しませんでした」で終えず**次に打つべきコマンドを名指しする**。この関門を踏むのは
  /// `orb` を打とうとして外した場合が主で、黙って落とすと制御 API の `Orbe not running` と同じく
  /// 原因から最も遠い方向——「Orbe が動いていないのでは」——へ誘導してしまう。
  static let rejectionMessage = """
    orbe: this is the Orbe application binary, not a command-line tool. It takes no arguments.

      To control the running Orbe instance, use `orb`:
        orb ws list
        orb --help

      To launch the app, open it from Finder or run `open -a Orbe`.

    """
}
