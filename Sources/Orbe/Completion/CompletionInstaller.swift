import Foundation

/// ユーザ資産 `~/.zshrc`（`$ZDOTDIR` 設定時は `$ZDOTDIR/.zshrc`）に Orbe 所有の managed block を
/// 冪等に追記/除去する。block は env `ORBE_COMPLETION_ZSH` をガードに source するので、Orbe が
/// 起こした shell でのみ効き、非 Orbe shell では完全 no-op。文言が固定＝冪等性が自明。
/// マーカー対の内側だけを書換え、block 外は不可侵。
enum CompletionInstaller {
  private static let beginMarker = "# >>> orbe completion >>>"
  private static let endMarker = "# <<< orbe completion <<<"
  private static let block = """
    # >>> orbe completion >>>
    [[ -n $ORBE_COMPLETION_ZSH ]] && source "$ORBE_COMPLETION_ZSH"
    # <<< orbe completion <<<
    """

  /// 編集対象の zshrc。`$ZDOTDIR`（非空）を尊重し、無ければ home 直下。
  static var zshrcURL: URL {
    let env = ProcessInfo.processInfo.environment
    let dir =
      env["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 }
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: dir).appendingPathComponent(".zshrc")
  }

  /// managed block を冪等に追記する。既にマーカー対があればその範囲だけ置換、無ければ末尾に 1 個追記。
  /// zshrc 不在なら新規作成。
  static func install(at url: URL = zshrcURL) {
    let target = url.resolvingSymlinksInPath()  // symlink な zshrc（dotfile 管理）は実体へ書く
    let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
    let updated = applyBlock(to: existing)
    try? updated.write(to: target, atomically: true, encoding: .utf8)
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
  static func uninstall(at url: URL = zshrcURL) {
    let target = url.resolvingSymlinksInPath()  // symlink な zshrc（dotfile 管理）は実体を書く
    guard let text = try? String(contentsOf: target, encoding: .utf8) else { return }
    var lines = text.components(separatedBy: "\n")
    guard let range = markerRange(in: lines) else { return }
    var start = range.lowerBound
    // install が入れた前置の空行を 1 つ巻き込む。
    if start > 0, lines[start - 1].isEmpty { start -= 1 }
    lines.removeSubrange(start...range.upperBound)
    try? lines.joined(separator: "\n").write(to: target, atomically: true, encoding: .utf8)
  }

  /// マーカー対があれば内側を置換、無ければ空行 1 つを挟んで末尾に追記する（純関数・テスト容易）。
  static func applyBlock(to text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    let blockLines = block.components(separatedBy: "\n")
    if let range = markerRange(in: lines) {
      lines.replaceSubrange(range, with: blockLines)
      return lines.joined(separator: "\n")
    }
    var result = text
    if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }  // 末尾改行を保証
    if !result.isEmpty { result += "\n" }  // block 前の空行
    result += block + "\n"
    return result
  }
}
