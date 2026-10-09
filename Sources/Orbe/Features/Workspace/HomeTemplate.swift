/// Home の root に置くファイルの雛形。画面の文言ではなくファイルの中身なので、UI 文言の辞書には載せない。
enum HomeTemplate {
  /// 秘書への指示（Orbe が持ち、起動のたびに書き直す）。
  static func rules(_ language: Language) -> String {
    switch language {
    case .ja: return rulesJa
    case .en: return rulesEn
    }
  }

  /// 人と AI が自由に書く欄（フォルダを作るときに 1 回だけ置く）。
  static func claudeMd(_ language: Language) -> String {
    switch language {
    case .ja: return claudeMdJa
    case .en: return claudeMdEn
    }
  }

  private static let rulesJa = """
    # Orbe の秘書

    このフォルダは Home の root です。ここで起動した claude は Orbe の秘書として働きます。

    ## 役割

    - 人から頼まれたことをする。頼まれていない間は何もしない。
    - 新しいタスク・並び順・期限の判断は提案にとどめ、人が決める。

    ## Orbe の操作

    - タスクの読み書き、タブや agent の操作は Orbe の MCP ツールで行う。
    - MCP が使えなければ `orb` CLI を使う（`orb --help`）。

    このファイルは Orbe が起動のたびに書き直す。書き足したいことは CLAUDE.md に書く。

    """

  private static let rulesEn = """
    # Orbe secretary

    This folder is the root of Home. A claude started here works as Orbe's secretary.

    ## Role

    - Do what the user asks. Do nothing while nothing is asked.
    - Only propose new tasks, ordering, and deadlines; the user decides.

    ## Operating Orbe

    - Read and write tasks, and operate tabs and agents, with Orbe's MCP tools.
    - If MCP is unavailable, use the `orb` CLI (`orb --help`).

    Orbe rewrites this file at every launch. Put your own additions in CLAUDE.md.

    """

  private static let claudeMdJa = """
    # Home

    秘書の役割と Orbe の操作は `.claude/rules/orbe.md` にあり、Orbe が起動のたびに更新する。

    このファイルは人も AI も自由に書き換えてよい。Orbe は上書きしない。

    """

  private static let claudeMdEn = """
    # Home

    The secretary's role and how to operate Orbe live in `.claude/rules/orbe.md`, which Orbe updates at every launch.

    Both the user and AI may edit this file freely. Orbe never overwrites it.

    """
}
