import AppKit

/// 旧補完方式（zshrc への managed block 追記）の後始末。新規に block を書く者はいない——
/// 過去バージョンが書いた block を起動時に一度だけ除去する。マーカー対の内側だけを除去し、
/// block 外は不可侵。
enum CompletionLegacyCleanup {
  private static let beginMarker = "# >>> orbe completion >>>"
  private static let endMarker = "# <<< orbe completion <<<"

  /// 除去対象の zshrc。旧 install が書いた場所と同じ解決（ユーザーの `$ZDOTDIR` 尊重・無ければ
  /// home 直下）なので除去も同じ場所を見る。GUI プロセスの ZDOTDIR は `CompletionShim.activate()`
  /// が shim へ向けた後なので、元の値は ORBE_USER_ZDOTDIR → shim 以外の ZDOTDIR の順で引く。
  static var zshrcURL: URL {
    let env = ProcessInfo.processInfo.environment
    let dir =
      env["ORBE_USER_ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 }
      ?? env["ZDOTDIR"].flatMap { $0.isEmpty || $0 == CompletionShim.directoryPath ? nil : $0 }
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: dir).appendingPathComponent(".zshrc")
  }

  /// managed block のマーカー対の範囲。無ければ nil。
  /// end は begin 始点のスライスから探すため常に begin <= end が成立する。
  private static func markerRange(in lines: [String]) -> ClosedRange<Int>? {
    guard let begin = lines.firstIndex(of: beginMarker),
      let end = lines[begin...].firstIndex(of: endMarker)
    else { return nil }
    return begin...end
  }

  /// マーカー対（前置の空行込み）を除去する。block 外は一切触らない。
  static func removeManagedBlock(at url: URL = zshrcURL) {
    let target = url.resolvingSymlinksInPath()  // symlink な zshrc（dotfile 管理）は実体を書く
    guard let text = try? String(contentsOf: target, encoding: .utf8) else { return }
    var lines = text.components(separatedBy: "\n")
    guard let range = markerRange(in: lines) else { return }
    var start = range.lowerBound
    // 旧 install が入れた前置の空行を 1 つ巻き込む。
    if start > 0, lines[start - 1].isEmpty { start -= 1 }
    lines.removeSubrange(start...range.upperBound)
    try? lines.joined(separator: "\n").write(to: target, atomically: true, encoding: .utf8)
  }
}

extension WindowController {
  /// 旧方式が zshrc へ書いた managed block を一度だけ除去する（幽霊を残さない）。
  /// block が source ガードにする env は立たなくなり不活性だが、掃除して flag も消す。
  func cleanupLegacyCompletionIfNeeded() {
    guard AppStatePersistence.load()?.completionInstalled == true else { return }
    DispatchQueue.global(qos: .utility).async {
      CompletionLegacyCleanup.removeManagedBlock()
      DispatchQueue.main.async {
        AppStatePersistence.update { $0.completionInstalled = nil }
      }
    }
  }
}
