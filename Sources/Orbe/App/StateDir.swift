import Foundation
import OrbePaths

/// state（workspaces.json・control.sock）の置き場。解決は OrbePaths に委譲する
/// （GUI 本体・`orb` CLI・MCP の 3 実行体で 1 実装を共有）。
/// `ORBE_STATE_DIR` が非空ならその直下へ隔離、未設定なら Apple 規定の application support 直下。
enum StateDir {
  /// state ディレクトリ。存在しなければ作成する。解決できなければ nil。
  static func base() -> URL? { OrbePaths.stateDirBase() }

  /// `ORBE_STATE_DIR` で隔離した検証用のインスタンスか。隔離したインスタンスは state フォルダの外を書かない。
  static var isIsolated: Bool {
    ProcessInfo.processInfo.environment[OrbePaths.stateDirEnvVar]?.isEmpty == false
  }

  /// このインスタンスの bundle ID（チャネル identity）。タブへ注入し、実体化コピーへも刻む。
  static var bundleId: String { OrbePaths.bundleId }
}
