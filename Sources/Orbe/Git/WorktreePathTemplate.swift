import Foundation

/// worktree 作成先パスのテンプレート展開（純ロジック・I/O 非依存）。
/// `{repo}`/`{slug}` トークンを展開し、~/絶対/相対（**リポジトリルート基準**）を解決して絶対パス化する。
/// slug サニタイズ（`/`→`-`）の唯一の真実もここが持ち、`DispatchDataProvider` の 4 経路が共有する。
enum WorktreePathTemplate {
  /// 未設定時の既定。リポジトリルート基準で解決すると現状導出
  /// `<リポジトリ親>/<repo名>-worktrees/<slug>` と完全一致する（後方互換の SSOT）。
  static let defaultTemplate = "../{repo}-worktrees/{slug}"

  /// 展開できるトークン（`{名前}`）。これ以外はすべて未知トークンとして検証で拒否する。
  static let knownTokens: Set<String> = ["repo", "slug"]

  /// テンプレに必須のブランチ変動トークン。欠くと全 worktree が同一パスへ衝突するため。
  static let requiredTokens: Set<String> = ["slug"]

  /// テンプレ検証の失敗理由（インラインエラー文言の分岐に使う）。
  enum Invalid: Equatable { case empty, missingSlug, unknownToken(String) }

  /// ブランチ名 → slug（`/`→`-`）。ブランチ由来トークンを ASCII スラッグに保つ唯一の真実。
  static func slug(_ branch: String) -> String {
    branch.replacingOccurrences(of: "/", with: "-")
  }

  /// テンプレを検証する（nil＝妥当）。検証点は `SettingChange` の domain と編集面が共有する。
  /// 空/必須トークン欠落/未知トークンを拒否する（`{repo}` 欠落は許容＝単一リポジトリでは不要）。
  static func validate(_ template: String) -> Invalid? {
    guard !template.trimmingCharacters(in: .whitespaces).isEmpty else { return .empty }
    let found = tokens(in: template)
    if let unknown = found.first(where: { !knownTokens.contains($0) }) {
      return .unknownToken(unknown)
    }
    guard !requiredTokens.isDisjoint(with: found) else { return .missingSlug }
    return nil
  }

  /// テンプレを絶対パスへ展開する。`repoRoot` は相対解決の基準（リポジトリルート＝CWD 基準にしない）。
  /// 前後空白は `validate` の空判定と同じく無意味とみなして落とす（先頭空白で絶対→相対に化けるのを防ぐ）。
  static func expand(_ template: String, repoRoot: String, branch: String) -> String {
    let substituted =
      template.trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "{repo}", with: (repoRoot as NSString).lastPathComponent)
      .replacingOccurrences(of: "{slug}", with: slug(branch))
    return resolve(substituted, repoRoot: repoRoot)
  }

  /// 置換後の文字列を絶対パス化する: 先頭 `~`＝ホーム展開・先頭 `/`＝絶対・それ以外＝repoRoot 基準の相対。
  /// `standardizingPath` が `..` を字句的に畳むため、既定テンプレの `..` が現状のリポジトリ親へ解決する。
  private static func resolve(_ path: String, repoRoot: String) -> String {
    let ns = path as NSString
    if path.hasPrefix("~") { return (ns.expandingTildeInPath as NSString).standardizingPath }
    if path.hasPrefix("/") { return ns.standardizingPath }
    return ((repoRoot as NSString).appendingPathComponent(path) as NSString).standardizingPath
  }

  /// テンプレ中の `{...}` トークン名を抽出する（順序保持・重複可）。未対応の `{` `}` は温存せず握り潰す。
  private static func tokens(in template: String) -> [String] {
    var result: [String] = []
    var inside = false
    var current = ""
    for ch in template {
      switch ch {
      case "{": inside = true; current = ""
      case "}": if inside { result.append(current) }; inside = false
      default: if inside { current.append(ch) }
      }
    }
    return result
  }
}
