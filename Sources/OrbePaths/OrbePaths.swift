import Foundation

/// state（workspaces.json・control.sock）と制御ソケットの置き場を、GUI 本体・`orb` CLI・
/// MCP ブリッジの 3 実行体で共有する単一の解決器。
///
/// 解決規則:
/// - state dir: `ORBE_STATE_DIR`（非空なら隔離）→ Apple 規定の `~/Library/Application Support/<bundle-id>/`
/// - control.sock: `ORBE_STATE_DIR`（非空の明示指定。`ORBE_SOCK` は見ない）→ `ORBE_SOCK`
///   （GUI がペインへ注入する実パス）→ `appSupportDir()/control.sock`
///
/// クライアントの socket 解決はサーバ（ControlServer = `stateDirBase()/control.sock`）と同じ
/// `stateDirBase()` を通るため、一致は偶然でなく構造として保証される。
public enum OrbePaths {
  /// bundle を持たない実行体（CLI/MCP）の fallback bundle id。GUI では
  /// `Bundle.main.bundleIdentifier` が優先されるが、ビルド時のチャネルから導出するため
  /// 同じチャネルで焼かれた GUI の Info.plist と必ず同値になる（`build-app.sh` が両方を導出する）。
  public static let fallbackBundleId: String = {
    #if ORBE_RELEASE
      return "dev.orbe.app"
    #else
      return "dev.orbe.app.dev"
    #endif
  }()

  /// runtime 契約の環境変数名（GUI がペインへ注入し、CLI/report/補完が読む）。
  public static let stateDirEnvVar = "ORBE_STATE_DIR"
  public static let sockEnvVar = "ORBE_SOCK"

  private static let fileManager = FileManager.default

  /// Apple 規定の `~/Library/Application Support/<bundle-id>/`。`ORBE_STATE_DIR` を一切見ない
  /// （全インスタンス共有の固定パスが要る用途向け）。存在しなければ作成する。解決不能なら nil。
  public static func appSupportDir() -> URL? {
    let id = Bundle.main.bundleIdentifier ?? fallbackBundleId
    guard
      let support = try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    let dir = support.appendingPathComponent(id, isDirectory: true)
    try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// state ディレクトリ。`ORBE_STATE_DIR` が非空ならその直下へ隔離、未設定なら `appSupportDir()`。
  /// 存在しなければ作成する。解決不能なら nil。env はテスト seam（既定は実環境）。
  public static func stateDirBase(
    env: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    if let override = env[stateDirEnvVar], !override.isEmpty {
      let dir = URL(fileURLWithPath: override, isDirectory: true)
      try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }
    return appSupportDir()
  }

  /// control.sock の絶対パス。`ORBE_STATE_DIR`（明示指定）が非空なら `$ORBE_STATE_DIR/control.sock`
  /// を使い、`ORBE_SOCK` は見ない（明示＞暗黙）。未設定時は `ORBE_SOCK`（GUI がペインへ注入する
  /// 実パス）→ `appSupportDir()/control.sock`。解決不能なら nil。env はテスト seam（既定は実環境）。
  public static func controlSocketPath(
    env: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    if let dir = env[stateDirEnvVar], !dir.isEmpty {
      return stateDirBase(env: env)?
        .appendingPathComponent("control.sock", isDirectory: false).path
    }
    if let sock = env[sockEnvVar], !sock.isEmpty { return sock }
    return stateDirBase(env: env)?
      .appendingPathComponent("control.sock", isDirectory: false).path
  }
}
