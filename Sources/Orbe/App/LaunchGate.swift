import Foundation

/// 起動が LaunchServices（Finder / Dock / `open`）を経由したかを見分ける。
enum LaunchGate {
  static let launchSourceEnvVar = "ORBE_LAUNCH_SOURCE"
  static let appLaunchSource = "app"

  enum Decision: Equatable {
    case proceed
    case reject
  }

  /// 起動経路の環境変数を読み、同時にプロセス env から削除する。
  ///
  /// 削除しないとペインがこの変数を継承し、ペインの中で打った `orbe` が LaunchServices 起動に
  /// 見えて関門を通ってしまう。読み取りと削除を分けると消し忘れが起きるため 1 操作にする。
  @discardableResult
  static func consumeLaunchSource() -> String? {
    let value = ProcessInfo.processInfo.environment[launchSourceEnvVar]
    unsetenv(launchSourceEnvVar)
    return value
  }

  /// LaunchServices 経由の起動や `ORBE_STATE_DIR` を持つ検証用の隔離インスタンス、`.app` バンドルを
  /// 持たない `swift run` の開発起動——新規ウィンドウが開いて正常なものは通す。
  /// ただしシェルからコマンドとして叩かれた起動は通さない。
  static func decide(isBundled: Bool, launchSource: String?, stateDir: String?) -> Decision {
    guard isBundled else { return .proceed }
    if launchSource == appLaunchSource { return .proceed }
    if let stateDir, !stateDir.isEmpty { return .proceed }
    return .reject
  }
}
