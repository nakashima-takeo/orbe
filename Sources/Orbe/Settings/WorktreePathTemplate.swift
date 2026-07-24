import Foundation

/// 設定 `worktree-dir`（Dispatch の worktree 作成先テンプレート）の検証と解決の純関数。
/// 語彙は `{parent}`（main worktree の親）・`{repo}`（main worktree の basename）・
/// `{slug}`（branch 名の `/`→`-`）の 3 語＋先頭 `~` のみ。書込の全経路
/// （設定パレット・orb config・control config_set）は `SettingDomain.validate` 経由で
/// `validate(_:)` を通り、読出（DispatchDataProvider）は `resolve` で作成先を確定する。
enum WorktreePathTemplate {
  static let placeholders = ["{parent}", "{repo}", "{slug}"]
  /// 未設定時の既定（従来のハードコード規則 `<親>/<repo名>-worktrees/<slug>` と同一パスに解決する）。
  static let defaultTemplate = "{parent}/{repo}-worktrees/{slug}"

  /// 不正理由（表示文言への写像は提示側が持つ）。
  enum ValidationError: Equatable {
    /// `{...}` が 3 語以外、または `{` の閉じ忘れ（associated value は問題の断片）。
    case unknownToken(String)
    /// `{slug}` を含まない（全 branch が同一パスへ落ちて必ず衝突する）。
    case missingSlug
    /// ダミー値で解決しても絶対パスにならない（相対解決の曖昧さを持ち込まない）。
    case notAbsolute
  }

  /// テンプレートを検証する（nil＝妥当）。空文字は `{slug}` を含まないため missingSlug で落ちる
  /// （「空＝解除」はパレット・control の nil 代入が担い、値としての空は受けない）。
  static func validate(_ template: String) -> ValidationError? {
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "{") {
      let fromOpen = rest[open...]
      guard let close = fromOpen.firstIndex(of: "}") else {
        return .unknownToken(String(fromOpen))  // 閉じ忘れ
      }
      let token = String(fromOpen[...close])
      guard placeholders.contains(token) else { return .unknownToken(token) }
      rest = fromOpen[fromOpen.index(after: close)...]
    }
    guard template.contains("{slug}") else { return .missingSlug }
    guard resolve(template: template, parent: "/parent", repo: "repo", slug: "slug").hasPrefix("/")
    else { return .notAbsolute }
    return nil
  }

  /// プレースホルダ置換 → 先頭 `~` 展開 → standardize で作成先パスを確定する。
  static func resolve(template: String, parent: String, repo: String, slug: String) -> String {
    let replaced =
      template
      .replacingOccurrences(of: "{parent}", with: parent)
      .replacingOccurrences(of: "{repo}", with: repo)
      .replacingOccurrences(of: "{slug}", with: slug)
    return ((replaced as NSString).expandingTildeInPath as NSString).standardizingPath
  }
}
