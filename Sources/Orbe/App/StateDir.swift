import Foundation
import OrbePaths

/// state（workspaces.json・control.sock）の置き場。解決は OrbePaths に委譲する
/// （GUI 本体・`orb` CLI・MCP の 3 実行体で 1 実装を共有）。
/// `ORBE_STATE_DIR` が非空ならその直下へ隔離、未設定なら Apple 規定の application support 直下。
enum StateDir {
  /// state ディレクトリ。存在しなければ作成する。解決できなければ nil。
  static func base() -> URL? { OrbePaths.stateDirBase() }

  /// Apple 規定の `~/Library/Application Support/<bundle-id>/`。`ORBE_STATE_DIR` を一切見ない
  /// （全インスタンス共有の固定パスが要る用途向け）。存在しなければ作成する。
  static func appSupport() -> URL? { OrbePaths.appSupportDir() }
}
