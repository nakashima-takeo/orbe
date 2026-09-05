import Foundation

/// Orbe runtime 契約の環境変数。タブが materialize 開始時に surface の起動 env へ注入し、
/// 同梱 CLI（bare `orb`）・エージェント hook（シム → orbe-report）・zsh 補完が読む。
/// hook はこれらが無ければ no-op。
/// - ORBE_TAB: 報告元のタブ。
/// - ORBE_BUNDLE_ID: このインスタンスのチャネル identity。シムが他チャネルの plugin から来た
///   呼び出しを落とすのに使う（`.app` でなくても常に名乗る。同梱 binary が無ければシムが先に no-op）。
/// - ORBE_REPORT_BIN: 同梱 binary の絶対パス（`swift run` では未解決→未設定＝no-op）。
/// - ORBE_SOCK: このインスタンスの制御 socket。
/// - PATH: 同梱 CLI（bare `orb`）の bin/ を前置。衝突は改名で解消済みゆえ順序非依存で解決する。
enum OrbeRuntimeEnv {
  /// `.app` 同梱の状態報告 binary（`<bundle>/Contents/Resources/bin/orbe-report`）の絶対パス。
  /// `swift run`（バンドル無し）では nil → env 未注入で hook が no-op。
  static var reportBinaryPath: String? {
    guard let resources = BundledResources.root else { return nil }
    let path = resources.appendingPathComponent("bin/orbe-report").path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
  }

  /// `.app` 同梱 CLI（`<bundle>/Contents/Resources/bin`。bare `orb` を含む）のディレクトリ。
  /// `swift run`（バンドル無し）では nil → PATH 注入なし。
  static var bundledBinDir: String? {
    guard let resources = BundledResources.root else { return nil }
    let path = resources.appendingPathComponent("bin").path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
      return nil
    }
    return path
  }

  /// 同梱 CLI（bare `orb`）を解決させるため bin/ を PATH 先頭へ前置する。既存 PATH（agent タブは
  /// initialEnv の login PATH・その他は本プロセスの PATH）を保持して前置だけ行う（login シェルの
  /// path_helper 越しでも bin/ が残る）。バンドル無し（swift run）では no-op。
  static func prependBundledBin(to env: inout [String: String]) {
    guard let binDir = bundledBinDir else { return }
    let base = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
    env["PATH"] = base.isEmpty ? binDir : "\(binDir):\(base)"
  }

  static func inject(into env: inout [String: String], tabId: Int) {
    prependBundledBin(to: &env)
    env["ORBE_TAB"] = String(tabId)
    env["ORBE_BUNDLE_ID"] = StateDir.bundleId
    if let bin = reportBinaryPath { env["ORBE_REPORT_BIN"] = bin }
    let sock = ControlServer.shared.socketPath
    if !sock.isEmpty { env["ORBE_SOCK"] = sock }
  }
}
