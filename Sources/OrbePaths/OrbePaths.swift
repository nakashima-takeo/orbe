import Foundation

/// state（workspaces.json・control.sock）と制御ソケットの置き場を、GUI 本体・`orb` CLI・
/// MCP ブリッジの 3 実行体で共有する単一の解決器。
///
/// 解決規則:
/// - state dir: `ORBE_STATE_DIR`（非空なら隔離）→ Apple 規定の `~/Library/Application Support/<bundle-id>/`
/// - control.sock: `ORBE_STATE_DIR`（非空の明示指定。`ORBE_SOCK` は見ない）→ `ORBE_SOCK`
///   （GUI がタブへ注入する実パス）→ `appSupportDir()/control.sock`
///
/// クライアントの socket 解決はサーバ（ControlServer = `stateDirBase()/control.sock`）と同じ
/// `stateDirBase()` を通るため、一致は偶然でなく構造として保証される。
public enum OrbePaths {
  /// ビルドのチャネル。公開版が release、それ以外（`swift build` の素の実行体を含む）は dev。
  public enum Channel: Sendable {
    case dev, release
  }

  /// このビルドのチャネル。ビルド時の `ORBE_RELEASE` を読むのはここだけで、チャネルで分かれる値はこれから導く。
  public static let channel: Channel = {
    #if ORBE_RELEASE
      return .release
    #else
      return .dev
    #endif
  }()

  /// bundle を持たない実行体（CLI/MCP）の fallback bundle id。GUI では
  /// `Bundle.main.bundleIdentifier` が優先されるが、ビルド時のチャネルから導出するため
  /// 同じチャネルで焼かれた GUI の Info.plist と必ず同値になる（`build-app.sh` が両方を導出する）。
  public static var fallbackBundleId: String {
    switch channel {
    case .release: "dev.orbe.app"
    case .dev: "dev.orbe.app.dev"
    }
  }

  /// このプロセスの bundle ID（＝チャネル identity）。バンドルを持たない実行体では焼き込み値へ落ちる。
  /// state の置き場（`appSupportDir()`）とタブへ注入する identity が同じ解決を通ることを構造で保証する。
  public static var bundleId: String { Bundle.main.bundleIdentifier ?? fallbackBundleId }

  /// runtime 契約の環境変数名（GUI がタブへ注入し、CLI/report/補完が読む）。
  public static let stateDirEnvVar = "ORBE_STATE_DIR"
  public static let sockEnvVar = "ORBE_SOCK"

  private static let fileManager = FileManager.default

  /// Apple 規定の `~/Library/Application Support/<bundle-id>/`。`ORBE_STATE_DIR` を一切見ない
  /// （全インスタンス共有の固定パスが要る用途向け）。存在しなければ作成する。解決不能なら nil。
  public static func appSupportDir() -> URL? {
    guard
      let support = try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    let dir = support.appendingPathComponent(bundleId, isDirectory: true)
    try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// 隔離先の state ディレクトリ。`ORBE_STATE_DIR` が非空のときだけその場所を返し、そうでなければ nil
  /// （隔離起動でない）。フォルダは作らない。env はテスト seam（既定は実環境）。
  public static func isolatedStateDir(
    env: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    guard let dir = env[stateDirEnvVar], !dir.isEmpty else { return nil }
    return URL(fileURLWithPath: dir, isDirectory: true)
  }

  /// state ディレクトリ。隔離先（`isolatedStateDir`）があればそこ、無ければ `appSupportDir()`。
  /// 存在しなければ作成する。解決不能なら nil。env はテスト seam（既定は実環境）。
  public static func stateDirBase(
    env: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    guard let dir = isolatedStateDir(env: env) else { return appSupportDir() }
    try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// control.sock の絶対パス。`ORBE_STATE_DIR`（明示指定）が非空なら `$ORBE_STATE_DIR/control.sock`
  /// を使い、`ORBE_SOCK` は見ない（明示＞暗黙）。未設定時は `ORBE_SOCK`（GUI がタブへ注入する
  /// 実パス）→ `appSupportDir()/control.sock`。解決不能なら nil。env はテスト seam（既定は実環境）。
  public static func controlSocketPath(
    env: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    if isolatedStateDir(env: env) == nil, let sock = env[sockEnvVar], !sock.isEmpty { return sock }
    return stateDirBase(env: env)?
      .appendingPathComponent("control.sock", isDirectory: false).path
  }
}
