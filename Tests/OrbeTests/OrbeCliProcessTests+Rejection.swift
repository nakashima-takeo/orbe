import Foundation
import XCTest

@testable import Orbe

/// `orb` が**解釈できなかったトークン**を捨てずに落とすことを、全 16 サブコマンドで固定する。
/// 契約そのもの（終了コード・`--workspace` の意味論）は `OrbeCliProcessTests+Contract` が持ち、
/// こちらは「取り切った後に残ったトークン」と「値の席に来た形」の 2 経路だけを見る。
/// 残余は `-` 始まりだけでなく**席から溢れた位置引数**も見る——`--dir` を書き忘れた `orb tab new /repo`
/// は `-` を持たないので、席の数を見なければ同じ被害へ別の入口から入る。
///
/// 壊れると何が起きるか: どちらの経路も、捨てられたトークンは exit 0 にも stdout にも stderr にも
/// 現れないまま**指定と違う対象**を触る。`tab new` はアクティブ WS にタブが生え、`ws new` は既定
/// root の workspace ができ、`pane close` / `tab close` は指定と無関係な現ペイン・現タブを消す。
/// 人間も自動化も、成功したと読んだまま気づけない。
extension OrbeCliProcessTests {
  /// `--workspace` の抜き取りは綴りが**完全一致**した 1 個目しか見ないので、`--workspace=3`（= 区切り）・
  /// 綴り誤り・2 個目の指定は残余トークンに落ちる。残余を検査しないとそれらは黙って捨てられ、
  /// exit 0 のまま**指定と違う workspace** を触る——`tab new` はアクティブ WS にタブが生え、
  /// `pane list` は絞り込みが効かず全 WS のペインが出る。終了コードにも stdout にも現れない。
  ///
  /// `-` 始まりを値として通す席は `config set <key> <value>` の `<value>` だけ（`config set font-size -1`）。
  /// この境界を「残余に `-` があれば一律エラー」に広げると負の値がすべて usage エラーに化け、逆に
  /// `<key>` の席まで広げると綴り誤ったフラグが key として control へ送られ、誤りの所在が
  /// 「引数を直せ（2）」ではなく「Orbe が拒否した（1）」に化ける。
  func testUnconsumedFlagLikeTokensAreRejectedInsteadOfSilentlyDropped() throws {
    let control = try startControlProcess()

    for args in [
      ["tab", "new", "--workspace=3"],
      ["pane", "list", "--workspace=3"],
      ["pane", "list", "--workspce", "3"],
      ["config", "list", "--workspace=3"],
      ["config", "get", "font-size", "--workspace=3"],
      // 黙って捨てると `--workspace` 自体が消えて scope が global に落ち、指定 WS の上書きでは
      // なく**global の明示値**が外れる（全 workspace の実効値が変わる）。
      ["config", "unset", "font-size", "--workspace=3"],
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

    // `<key>` の席は通さない。通すと綴り誤ったフラグが key として control へ渡り、`get` / `unset`
    // が同じ入力を exit 2 で弾くのに `set` だけ exit 1（RPC エラー）に化ける。
    for args in [["config", "set", "-x", "5"], ["config", "set", "--workspce", "3"]] {
      failure(
        ControlProcess.orbWithoutServer(args), code: 2,
        message: "config set requires <key> <value>",
        "`<key>` の席の `-` 始まり `\(args.joined(separator: " "))`")
    }
  }

  /// pane / tab コマンドは `--workspace` を取らないので、渡された `-` 始まりは必ず誤り。
  /// 黙って捨てたときの現れ方はコマンドで違う。`pane close` / `tab close` は `ORBE_PANE` 既定へ
  /// 落ち、**指定と無関係な現ペイン・現タブ**が exit 0 と `closed pane N` を出しながら消える
  /// （`tab close` なら同タブの全ペイン——走行中のエージェントやシェルセッション——が一括で失われ、
  /// 終了コードにも stdout にも stderr にも現れないので人間も自動化も気づけない）。`pane split` は
  /// 指定と違うペインを分割する。`pane focus` は既定へ落ちないので破壊はしないが、「id が無い」と
  /// いう**誤りの所在を取り違えさせる**文言で落ちる。全部を `unknown option:` へ揃える。
  ///
  /// pane / tab の id は `IdGen` が 1 から採番するので常に正。よって位置引数の席にも例外を設けず、
  /// `config` 系（`config set font-size -1` の `-1` は値）と違って残余は先頭から検査する。
  /// socket に触れる前に落ちることを `orbWithoutServer` で固定する——ORBE_PANE が居ても
  /// 解決へ進まないのが要点で、サーバを立てて確かめると「消えなかった」ことしか見えない。
  func testPaneAndTabCommandsRejectFlagLikeTokens() {
    for args in [
      ["pane", "close", "--workspace", "3"],
      ["pane", "close", "--bogus"],
      ["pane", "split", "--workspace=3"],
      ["pane", "focus", "--workspace", "3"],
      ["tab", "close", "--workspace", "3"],
      ["pane", "close", "5", "--workspce", "3"],  // 位置引数の後ろに落ちた綴り誤り
    ] {
      failure(
        ControlProcess.orbWithoutServer(args, env: ["ORBE_PANE": "1"]), code: 2,
        message: "unknown option:",
        "解釈されなかったフラグを捨てた `\(args.joined(separator: " "))`")
    }
  }

  /// `ws` コマンドも残余を検査する。`ws new` は `tab new` と同じ `takeOption` で `--dir <path>` を
  /// 取るが、綴りが完全一致した 1 個目しか見ないので `--dir=/repo`（= 区切り）も綴り誤りも残余に落ちる。
  ///
  /// 壊れると何が起きるか: `orb ws new proj --dir=/repo` が既定 root の workspace を作って exit 0 と
  /// `created workspace N: proj` を出す。rootPath はその WS の全タブの cwd と worktree の基点なので、
  /// 以後そこで開くタブもエージェントも指定と違うディレクトリで走る。終了コードにも stdout にも
  /// 現れないうえ、同じ綴り誤りを `tab new` に渡すと exit 2 で弾かれる——同一フラグ・同一ヘルパで
  /// コマンドによって挙動が割れると、どちらが正しいのか利用者にも自動化にも決められない。
  ///
  /// workspace 名も `<id|current>` もパスも `-` 始まりを取らないので、pane/tab と同じく先頭から検査する。
  func testWorkspaceCommandsRejectFlagLikeTokens() {
    for args in [
      ["ws", "list", "--workspace", "3"],
      ["ws", "new", "proj", "--dir=/tmp/orbe-l4"],
      ["ws", "new", "proj", "--dirr", "/tmp/orbe-l4"],  // 綴り誤り
      ["ws", "rename", "3", "renamed", "--bogus"],
      ["ws", "dir", "3", "/tmp/orbe-l4", "--bogus"],
      ["ws", "switch", "3", "--bogus"],
      ["ws", "rm", "3", "--bogus"],
    ] {
      failure(
        ControlProcess.orbWithoutServer(args), code: 2, message: "unknown option:",
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
  /// `orb pane list 2` は絞り込みが効かず全 WS のペインが出て、`orb pane close 5 6` は 6 に触れない。
  /// いずれも exit 0 で、終了コードにも stdout にも stderr にも現れない。
  ///
  /// 16 サブコマンドを全て並べるのは、席の数が各コマンドの申告制だから——1 つ書き忘れても他が緑なら
  /// 気づけない。`ORBE_PANE` を置くのは、pane/tab が既定へ逸れる前に落ちることを見るため。
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
      ["pane", "list", "2"],
      ["pane", "split", "5", "6"],
      ["pane", "close", "5", "6"],
      ["pane", "focus", "5", "6"],
      ["tab", "new", "/tmp/orbe-l4"],  // --dir の書き忘れ
      ["tab", "close", "1", "2"],
    ] {
      failure(
        ControlProcess.orbWithoutServer(args, env: ["ORBE_PANE": "1"]), code: 2,
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
    for (args, message) in [
      (["tab", "new", "--dir", "--workspace", "2"], "--dir requires a <path> value"),
      (["tab", "new", "--dir", "--cmd", "claude"], "--dir requires a <path> value"),
      (["tab", "new", "--cmd", "--dir", "/tmp/orbe-l4"], "--cmd requires a value"),
      (["ws", "new", "--dir", "--bogus", "proj"], "--dir requires a <path> value"),
      // 値が無いまま終端した形も同じ文言で落ちる。
      (["tab", "new", "--dir"], "--dir requires a <path> value"),
      (["tab", "new", "--cmd"], "--cmd requires a value"),
      // 引用符付きで空になった形（トークンは消えず空文字として残る）。
      (["tab", "new", "--dir", "", "--cmd", "claude"], "--dir requires a <path> value"),
      (["tab", "new", "--cmd", ""], "--cmd requires a value"),
      (["ws", "new", "proj", "--dir", ""], "--dir requires a <path> value"),
    ] {
      failure(
        ControlProcess.orbWithoutServer(args), code: 2, message: message,
        "値の席が空いた `\(args.joined(separator: " "))`")
    }
  }
}
