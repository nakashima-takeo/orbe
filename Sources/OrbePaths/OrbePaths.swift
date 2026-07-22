import Foundation

/// state（workspaces.json・control.sock）と制御ソケットの置き場を、GUI 本体・`orb` CLI・
/// MCP ブリッジの 3 実行体で共有する単一の解決器。
///
/// 解決規則:
/// - state dir: `ORBE_STATE_DIR`（非空なら隔離）→ Apple 規定の `~/Library/Application Support/<bundle-id>/`
/// - control.sock: `ORBE_SOCK`（GUI がペインへ注入する実パス）→ `stateDirBase()/control.sock`
///
/// クライアントの socket 既定はサーバ（ControlServer）と同じ `appSupportDir()/control.sock` を
/// 通るため、一致は偶然でなく構造として保証される。
public enum OrbePaths {
  /// bundle を持たない実行体（CLI/MCP）の fallback bundle id。GUI では
  /// `Bundle.main.bundleIdentifier` が優先されるが、Info.plist と同値なので結果は一致する。
  public static let fallbackBundleId = "dev.orbe.app"

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
  /// 存在しなければ作成する。解決不能なら nil。
  public static func stateDirBase() -> URL? {
    if let override = ProcessInfo.processInfo.environment[stateDirEnvVar], !override.isEmpty {
      let dir = URL(fileURLWithPath: override, isDirectory: true)
      try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }
    return appSupportDir()
  }

  /// control.sock の絶対パス。`ORBE_SOCK`（注入された実パス）を最優先し、無ければ
  /// `stateDirBase()/control.sock`。解決不能なら nil。
  public static func controlSocketPath() -> String? {
    if let sock = ProcessInfo.processInfo.environment[sockEnvVar], !sock.isEmpty {
      return sock
    }
    guard let base = stateDirBase() else { return nil }
    return base.appendingPathComponent("control.sock", isDirectory: false).path
  }
}
