import Foundation
import XCTest

@testable import Orbe

/// `orb` が**解釈できなかったトークン**を捨てずに落とすことを固定する。
/// 契約そのもの（終了コード・`--workspace` の意味論）は `OrbeCliProcessTests+Contract` が持ち、
/// こちらは「取り切った後に残ったトークン」と「値の席に来た形」の 2 経路だけを見る。
/// 残余は `-` 始まりだけでなく**席から溢れた位置引数**も見る——`--dir` を書き忘れた `orb tab new /repo`
/// は `-` を持たないので、席の数を見なければ同じ被害へ別の入口から入る。
///
/// 壊れると何が起きるか: どちらの経路も、捨てられたトークンは exit 0 にも stdout にも stderr にも
/// 現れないまま**指定と違う対象**を触る。`tab new` はアクティブ WS にタブが生え、`ws new` は既定
/// root の workspace ができ、`tab close` は指定と無関係な現タブを消す。
/// 人間も自動化も、成功したと読んだまま気づけない。
extension OrbeCliProcessTests {
  /// `--workspace` の抜き取りは綴りが**完全一致**した 1 個目しか見ないので、`--workspace=3`（= 区切り）・
  /// 綴り誤り・2 個目の指定は残余トークンに落ちる。残余を検査しないとそれらは黙って捨てられ、
  /// exit 0 のまま**指定と違う workspace** を触る——`tab new` はアクティブ WS にタブが生え、
  /// `tab list` は絞り込みが効かず全 WS のタブが出る。終了コードにも stdout にも現れない。
  ///
  /// `-` 始まりを値として通す席は `config set <key> <value>` の `<value>` だけ（`config set font-size -1`）。
  /// この境界を「残余に `-` があれば一律エラー」に広げると負の値がすべて usage エラーに化ける。
  /// 反対側の境界（`<key>` の席）は `testConfigKeySlotRejectsFlagLikeTokensBeforeTouchingTheSocket` が持つ。
  ///
  /// `--workspace current` を含むケースが解決のため control を要るので、この 1 本だけサーバを立てる。
  func testUnconsumedFlagLikeTokensAreRejectedInsteadOfSilentlyDropped() throws {
    let control = try startControlProcess()

    // 判定は全サブコマンド共通の `rejectLeftovers` 1 つなので、抜き取りの経路ごとの代表だけを並べる
    // （値必須の `--workspace`・config の optional-value の `--workspace`・2 個目の指定）。
    for args in [
      ["tab", "new", "--workspace=3"],
      // 黙って捨てると `--workspace` 自体が消えて scope が global に落ち、指定 WS の上書きでは
      // なく**global の明示値**が外れる（全 workspace の実効値が変わる）。
      ["config", "unset", "font-size", "--workspace=3"],
      // `<value>` の席の外（3 席目）の `-` 始まりは値として通さない。
      ["config", "set", "theme", "dark", "--workspace", "-1"],
      ["config", "set", "font-size", "14", "--workspace", "current", "--workspace", "nosuch"],
    ] {
      failure(
        control.orb(args), code: 2, message: "unknown option:",
        "解釈されなかった `\(args.joined(separator: " "))`")
    }

    // `<value>` の席に来た `-` 始まりは値として解析を通る（弾きすぎの防止）。値域を見るのはサーバなので、
    // ここで確かめるのは「未知フラグとして前段で落とされない」ことだけ。
    let negative = control.orb(["config", "set", "font-size", "-1"])
    XCTAssertFalse(
      negative.stderr.contains("unknown option"),
      "`<value>` の席の `-1` を未知フラグとして弾いている: \(negative.stderr)")
  }

  /// `config` の `<key>` の席は `-` 始まりを通さない。残余検査は先頭 n 席をまるごと外すので、
  /// この席は各サブコマンドの guard が打ち消す。
  ///
  /// 壊れると何が起きるか: `orb config set --workspce 3 font-size 14` の綴り誤りが key として
  /// control へ渡り、`get` / `unset` が同じ入力を exit 2 で弾くのに `set` だけ exit 1（RPC エラー）
  /// に化ける。誤りの所在が「引数を直せ」ではなく「Orbe が拒否した」に見える。
  ///
  /// **サーバを立てない**のがこのテストの要点——立てると壊れた実装でも control が
  /// `unknown config key` を返して exit 2 に化け、終了コードの assert が判別力を失う。
  func testConfigKeySlotRejectsFlagLikeTokensBeforeTouchingTheSocket() {
    for args in [
      ["config", "set", "-x", "5"], ["config", "set", "--workspce", "3"],
      ["config", "get", "-x"], ["config", "unset", "-x"],
    ] {
      failure(
        ControlProcess.orbWithoutServer(args), code: 2, message: "requires <key>",
        "`<key>` の席の `-` 始まり `\(args.joined(separator: " "))`")
    }
  }

  /// `--workspace` を取らないコマンドに渡された `-` 始まりも、`--dir` の `=` 区切りも、socket に触れる前に
  /// 落ちる。黙って捨てたときの現れ方はコマンドで違う。`tab close` は `ORBE_TAB` 既定へ落ち、
  /// **指定と無関係な現タブ**——走行中のエージェントやシェルセッション——が exit 0 と
  /// `closed tab N` を出しながら消える。`orb ws new proj --dir=/repo` は既定 root の workspace を作り、
  /// 以後そこで開くタブもエージェントも指定と違うディレクトリで走る。どちらも終了コードにも stdout にも
  /// stderr にも現れないので人間も自動化も気づけない。
  ///
  /// `orbWithoutServer` で固定する——ORBE_TAB が居ても解決へ進まないのが要点で、サーバを立てて
  /// 確かめると「消えなかった」ことしか見えない。
  func testFlagLikeLeftoversAreRejectedBeforeTouchingTheSocket() {
    for args in [
      ["tab", "close", "--bogus"],
      ["tab", "close", "5", "--workspce", "3"],  // 位置引数の後ろに落ちた綴り誤り
      ["ws", "new", "proj", "--dir=/tmp/orbe-l4"],
    ] {
      failure(
        ControlProcess.orbWithoutServer(args, env: ["ORBE_TAB": "1"]), code: 2,
        message: "unknown option:",
        "解釈されなかったフラグを捨てた `\(args.joined(separator: " "))`")
    }
  }

  /// 位置引数の席から溢れたトークンも残余なので落とす。`-` を持たないので `unknown option:` の
  /// 検査は素通りし、席の数を見なければ黙って捨てられる——`--dir=/repo` は exit 2 で落ちるのに
  /// `--dir` ごと書き忘れた `/repo` は exit 0 で通る、という割れ方になる。
  ///
  /// 壊れると何が起きるか: `orb tab new /repo` が**アクティブ WS の既定 cwd**にタブを開き、
  /// `orb ws new proj /repo` が**既定 root** の workspace を作る（rootPath はその WS の全タブの cwd と
  /// worktree の基点なので、以後そこで開くタブもエージェントも指定と違うディレクトリで走る）。
  /// `orb tab list 2` は絞り込みが効かず全 WS のタブが出て、`orb tab close 5 6` は 6 に触れない。
  /// いずれも exit 0 で、終了コードにも stdout にも stderr にも現れない。
  ///
  /// 29 サブコマンド（`session restore` は位置引数が可変長で溢れが無い）を全て並べるのは、席の数が
  /// 各コマンドの申告制だから——1 つ書き忘れても他が緑なら気づけない。`ORBE_TAB` を置くのは、tab 系が既定へ逸れる前に落ちることを見るため。
  func testExcessPositionalsAreRejectedInsteadOfSilentlyDropped() {
    for args in [
      ["config", "list", "3"],
      ["config", "get", "font-size", "extra"],
      ["config", "set", "font-size", "14", "extra"],
      ["config", "unset", "font-size", "extra"],
      ["ws", "list", "3"],
      ["ws", "new", "proj", "/tmp/orbe-l4"],  // --dir の書き忘れ
      ["ws", "rename", "3", "renamed", "extra"],
      ["ws", "dir", "3", "/tmp/orbe-l4", "extra"],
      ["ws", "switch", "3", "4"],
      ["ws", "rm", "3", "4"],
      ["tab", "list", "2"],
      ["tab", "close", "5", "6"],
      ["tab", "focus", "5", "6"],
      ["tab", "new", "/tmp/orbe-l4"],  // --dir の書き忘れ
      ["tab", "text", "5", "6"],
      ["tab", "send", "5", "6", "--text", "hi"],
      ["tab", "key", "5", "6", "--key", "enter"],
      ["agent", "list", "extra"],
      ["agent", "spawn", "claude", "extra"],
      ["agent", "resume", "claude", "sess-1", "extra"],
      ["agent", "prompt", "5", "6", "--text", "hi"],
      ["session", "log", "extra"],
      ["session", "closed", "extra"],
      ["wait", "5", "6"],
      ["task", "list", "3"],
      ["task", "add", "経費", "精算"],  // 引用符の付け忘れ
      ["task", "set", "1", "2", "--title", "t"],
      ["task", "move", "1", "2", "--before", "3"],
      ["task", "rm", "1", "2"],
    ] {
      failure(
        ControlProcess.orbWithoutServer(args, env: ["ORBE_TAB": "1"]), code: 2,
        message: "unexpected argument:",
        "席から溢れた `\(args.joined(separator: " "))`")
    }
  }

  /// 値必須フラグ（`--dir` / `--cmd`）の値の席は空けられない——`-` 始まり・空文字・値なしは usage エラー。
  ///
  /// 飲むと**飲まれたトークンは残余に落ちない**ので `rejectLeftoverFlags` では捕まらない——門番を
  /// 全サブコマンドへ通しても塞がらない、値の席から入る別経路になる。
  ///
  /// 壊れると何が起きるか: `orb tab new --dir "$DIR" --cmd "$CMD"` の `$DIR` が空になる形が、
  /// 引用符の有無で 2 通り入る。無ければトークンごと消えて `orb tab new --dir --cmd claude` になり、
  /// cwd が `--cmd` のタブが**アクティブ WS** に開いて `claude` は捨てられる。あれば空文字が
  /// そのまま cwd として通り、`orb ws new proj --dir ""` は rootPath が空の workspace を作る。
  /// どちらも exit 0 で、終了コードにも stdout にも stderr にも現れない。
  func testValueTakingFlagsRejectFlagLikeValues() {
    // 次のフラグを値に飲む・値なしで終端・空（空白だけを含む）は全フラグ共通の `takeOption` の分岐なので、
    // 分岐ごとの代表だけを並べる。
    for (args, message) in [
      (["tab", "new", "--dir", "--cmd", "claude"], "--dir requires a <path> value"),
      (["tab", "new", "--dir"], "--dir requires a <path> value"),
      (["ws", "new", "proj", "--dir", ""], "--dir requires a <path> value"),
      (["tab", "send", "5", "--text", "  "], "--text requires a value"),
    ] {
      failure(
        ControlProcess.orbWithoutServer(args), code: 2, message: message,
        "値の席が空いた `\(args.joined(separator: " "))`")
    }
  }
}
