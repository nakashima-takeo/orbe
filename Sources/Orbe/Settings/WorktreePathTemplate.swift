import Foundation

/// 設定 `worktree-dir`（Dispatch の worktree 作成先テンプレート）の検証と解決の純関数。
/// 語彙は `{repo_path}`（main worktree の絶対パス）・`{parent}`（その親）・`{repo}`（その basename）・
/// `{slug}`（branch 名の `/`→`-`）の 4 語＋先頭 `~` のみ。書込の全経路
/// （設定パレット・orb config・control config_set）は `SettingDomain.validate` 経由で
/// `validate(_:)` を通り、読出（DispatchDataProvider）は `resolve` で作成先を確定する。
enum WorktreePathTemplate {
  static let placeholders = ["{repo_path}", "{parent}", "{repo}", "{slug}"]
  /// 未設定時の既定（従来のハードコード規則 `<親>/<repo名>-worktrees/<slug>` と同一パスに解決する）。
  static let defaultTemplate = "{parent}/{repo}-worktrees/{slug}"

  /// 設定パレットが一覧で出す作成場所の候補。テキスト入力は最終手段なので、よくある配置は
  /// 名前つきの行から 1 打で選べるようにする（一覧の最終行「カスタム…」は提示側が足す）。
  struct Preset {
    let template: String
    let labelKey: L10nKey
  }

  /// 先頭は `defaultTemplate` 自身＝未設定と同じ場所を明示的に選び直せる。
  static let presets: [Preset] = [
    Preset(template: defaultTemplate, labelKey: .settingsWorktreeDirPresetSibling),
    Preset(template: "~/worktrees/{repo}/{slug}", labelKey: .settingsWorktreeDirPresetHome),
    Preset(template: "{repo_path}/.worktrees/{slug}", labelKey: .settingsWorktreeDirPresetInside),
    Preset(template: "{parent}/{repo}-{slug}", labelKey: .settingsWorktreeDirPresetFlat),
  ]

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
    guard resolve(template: template, repoPath: "/parent/repo", slug: "slug").hasPrefix("/")
    else { return .notAbsolute }
    return nil
  }

  /// リポジトリを区別する語を含むか（含まないテンプレートは別リポジトリの同名ブランチが同一パスへ落ちる）。
  /// 保存は拒否しない——1 リポジトリ専用の置き場を workspace 上書きで指定する使い方があるため、
  /// 提示側が警告に使う。
  static func distinguishesRepository(_ template: String) -> Bool {
    template.contains("{repo}") || template.contains("{repo_path}")
  }

  /// プレースホルダ置換 → 先頭 `~` 展開 → 正規化で作成先パスを確定する。
  /// 語彙は repo 本体の場所（main worktree の絶対パス）1 つから導く——`{repo_path}` と `{parent}/{repo}` が
  /// 定義上つねに同値であることを、呼び手の渡し方に頼らずここで担保する。そのため置換の前に場所自体を
  /// 正規化する: 末尾スラッシュ付き（`/a/repo/`）のまま置換すると `{repo_path}-wt` が `/a/repo/-wt`、
  /// `{parent}/{repo}-wt` が `/a/repo-wt` へ割れ、同値の担保が呼び手の書き方に逆戻りする。
  static func resolve(template: String, repoPath: String, slug: String) -> String {
    let base = lexicallyStandardized(repoPath)
    let path = base as NSString
    let replaced =
      template
      .replacingOccurrences(of: "{repo_path}", with: base)
      .replacingOccurrences(of: "{parent}", with: path.deletingLastPathComponent)
      .replacingOccurrences(of: "{repo}", with: path.lastPathComponent)
      .replacingOccurrences(of: "{slug}", with: slug)
    return lexicallyStandardized((replaced as NSString).expandingTildeInPath)
  }

  /// 字句だけの正規化（`.`・`..`・重複/末尾スラッシュを畳む）。**symlink は解決しない**——名前で
  /// Foundation の `standardizingPath` と取り違えないこと。あちらは**実在するパスだけ**リンクを解決し
  /// `/private` を畳むため、これから作る（＝実在しない）worktree パスと実在する repo root で結果が
  /// 食い違う。作成先の解決（`resolve`）と repo 内判定（`GitWorktreeExclude`）は同じ土俵で比べる
  /// 必要があるので、両者はこの純字句の正規化 1 本を共有する。
  static func lexicallyStandardized(_ path: String) -> String {
    let isAbsolute = path.hasPrefix("/")
    var components: [String] = []
    for component in path.split(separator: "/") where component != "." {
      if component == ".." {
        // 絶対パスの `/..` は `/`（POSIX）＝捨てる。相対パスの先頭 `..` は畳めない——落とすと
        // repo の外を指すテンプレートが中を指すものに反転する。
        if let last = components.last, last != ".." {
          components.removeLast()
        } else if !isAbsolute {
          components.append("..")
        }
      } else {
        components.append(String(component))
      }
    }
    return (isAbsolute ? "/" : "") + components.joined(separator: "/")
  }
}
