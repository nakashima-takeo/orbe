import JavaScriptCore
import XCTest

@testable import Orbe

/// engine が解析時に確定させた事実（照合トークン `query`・確定コマンド列 `commandPath`）を
/// 結果 payload が載せることを、実バンドルの出力で検証する。host はこれを生バッファから
/// 導き直さないので、ここが engine 側の契約の置き場になる。
/// 候補そのものの契約・シェルインジェクション・並び順は `CompletionEngineTests` が持つ。
extension CompletionEngineTests {
  func testEngineQueryIsNormalizedTokenDistinctFromReplaceLength() throws {
    // パス途中のトークンでは、置換すべき範囲（`sub/mai` の 7 文字）と候補名と比較できる部分
    // （basename の `mai`）が別物になる。engine は両方を出し、host は前者を編集座標に、
    // 後者を照合とプレフィックス強調に使う。basename 化は不可逆なので片方から他方は導けない。
    let h = try XCTUnwrap(
      EngineHarness(
        exec: { _ in "" },
        readdir: { _ in
          [(name: "main.swift", isDirectory: false), (name: "main.swift.orig", isDirectory: false)]
        }))
    let result = h.complete("cat sub/mai")
    XCTAssertEqual(names(result), ["main.swift", "main.swift.orig"], "候補名は basename 化されている")
    XCTAssertEqual(result["query"] as? String, "mai", "照合に使ったトークンは basename 部分")
    XCTAssertEqual(result["replaceLength"] as? Int, 7, "置換範囲はトークン全域")
  }

  func testEngineQueryEmptyForCompletePathToken() throws {
    // ディレクトリを打ち切った位置は「まだ何も打っていない」。照合トークンは空になる。
    // 置換範囲はトークン全域のまま（`sub/` の 4 文字）——照合トークンが空でも 0 に落ちない側で、
    // 「置換の座標」と「照合の入力」が別事実であることのもう一方の端。
    let h = try XCTUnwrap(
      EngineHarness(
        exec: { _ in "" },
        readdir: { _ in [(name: "main.swift", isDirectory: false)] }))
    let result = h.complete("cat sub/")
    XCTAssertEqual(result["query"] as? String, "", "打ち切ったパスの照合トークンは空")
    XCTAssertEqual(result["replaceLength"] as? Int, 4, "置換範囲はトークン全域のまま")
  }

  func testEngineQueryIsTypedTokenAtSubcommandPositions() throws {
    // subcommand / option を出す経路の照合トークンは打鍵そのまま（パスではないので basename 化する
    // 相手がいない）。トークンがまだ無い位置では空。ここが載らないと、この位置でだけ
    // プレフィックス強調と一致品質が静かに効かなくなる。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    XCTAssertEqual(h.complete("git commit --am")["query"] as? String, "--am", "option トークンは打鍵そのまま")
    XCTAssertEqual(h.complete("git ")["query"] as? String, "", "トークンがまだ無い位置は空")
  }

  func testEngineCommandPathAccumulatesConfirmedCommands() throws {
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    let root = h.complete("gi")
    XCTAssertEqual(root["commandPath"] as? [String], [], "コマンド名自体の補完では確定コマンドがまだ無い")
    XCTAssertEqual(root["query"] as? String, "gi", "照合トークンは打鍵そのまま")
    XCTAssertEqual(h.complete("git ")["commandPath"] as? [String], ["git"], "root だけ確定")
    let withFreeText = h.complete("git commit -m \"fix stuff\" --am")
    XCTAssertEqual(
      withFreeText["commandPath"] as? [String], ["git", "commit"],
      "オプションと引数の自由テキストは確定コマンド列に入らない")
  }

  func testEngineCommandPathIsStableAcrossAliases() throws {
    // `npm i` と `npm install` は同じ spec ノード＝同じ候補集合。確定コマンド列は spec ノードで
    // 一意に定まる名前で積むので、打鍵の綴りが違っても同じ列になり、学習キーが綴りで割れない。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    let short = h.complete("npm i --sa")
    let long = h.complete("npm install --sa")
    XCTAssertEqual(names(short), names(long), "同じ spec ノードなので候補集合は同一（前提）")
    XCTAssertEqual(
      short["commandPath"] as? [String], long["commandPath"] as? [String],
      "綴りが違っても確定コマンド列は同じ")
    XCTAssertEqual(short["commandPath"] as? [String], ["npm", "install"])
  }

  func testEngineCommandPathIncludesSubcommandAfterOptionArgument() throws {
    // オプションの引数位置を通り抜けてから確定したサブコマンドも確定コマンド列に積まれる。
    // 積み損ねると `["git"]` へ潰れ、`git commit` 位置の静的候補が `git` 直下と同じ学習キーへ
    // 混ざる（クラッシュも警告も出ず「学習が効かない」という遠い症状にしかならない）。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    XCTAssertEqual(
      h.complete("git --exec-path commit --am")["commandPath"] as? [String], ["git", "commit"],
      "オプションの引数位置を挟んでもサブコマンドは確定コマンド列へ入る")
  }

  func testEngineCommandPathKeepsIntermediateCommands() throws {
    // 入れ子が深くても確定した順に全要素が残る。中間要素が落ちると
    // `docker container ls` と `docker ls` が同じ学習キーへ畳まれる。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    XCTAssertEqual(
      h.complete("docker container ls -")["commandPath"] as? [String],
      ["docker", "container", "ls"], "確定したサブコマンドを順に保存する")
  }

  func testEngineCommandPathFollowsCommandSeparator() throws {
    // 確定コマンド列は buffer 先頭のコマンドではなく、engine が解析しているコマンド。
    // コマンド区切りの右側を補完している位置では、候補集合を決めているそちらが列になる。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    XCTAssertEqual(
      h.complete("ls | grep x ")["commandPath"] as? [String], ["grep"],
      "コマンド区切りの右側のコマンドが確定コマンド列になる")
  }

  func testEngineReportsConfirmedFactsWithoutCandidates() throws {
    // 解析事実は候補の有無と独立に「engine が確定させた分だけ」載る。自由テキストの引数位置は
    // 候補ゼロでも照合トークンと確定コマンド列を持つ＝「候補ゼロなら既定値」ではない。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    let result = h.complete("git commit -m fo")
    XCTAssertTrue(names(result).isEmpty, "自由テキストの引数位置に候補は出ない（前提）")
    XCTAssertEqual(result["query"] as? String, "fo", "打鍵中のトークンは載る")
    XCTAssertEqual(result["commandPath"] as? [String], ["git", "commit"], "確定済みのコマンド列も載る")
  }

  func testEngineLearningSurvivesFreeTextArgumentBetweenPositions() throws {
    // 引数の自由テキストを挟んだ位置（`git commit -m "fix stuff" --am`）で覚えたオプションが、
    // 同じコマンド列の別の打鍵位置（`git commit --a`）から引ける。engine が両方のバッファへ
    // 同じ確定コマンド列を返すので、record と rank が同じ静的スコープを引く。
    let h = try XCTUnwrap(EngineHarness { _ in "" })

    // accept 経路: 自由テキストを挟んだ位置の確定コマンド列から scopes を作って記録する。
    let accepted = h.complete("git commit -m \"fix stuff\" --am")
    let acceptedPath = try XCTUnwrap(accepted["commandPath"] as? [String])
    let store = try XCTUnwrap(
      CompletionLearning.record(
        scopes: CompletionLearning.scopes(commandPath: acceptedPath),
        candidate: "--amend", type: type(accepted, name: "--amend"), now: 1000, into: .empty),
      "実 engine の option type で record が発火する")

    // update 経路: 自由テキストの無い別バッファ。確定コマンド列が一致するので同じキーを引く。
    let typing = h.complete("git commit --a")
    XCTAssertEqual(typing["commandPath"] as? [String], acceptedPath, "自由テキストの有無で列は変わらない")
    let choices = (typing["suggestions"] as? [[String: Any]] ?? []).compactMap { s in
      (s["name"] as? String).map {
        CompletionChoice(
          value: $0, description: "", insertValue: s["insertValue"] as? String,
          type: s["type"] as? String)
      }
    }
    XCTAssertEqual(choices.first?.value, "--all", "engine 元順では --all が先頭・--amend は 2 番目（追い越しの前提）")
    let ranked = CompletionLearning.rank(
      choices, query: typing["query"] as? String ?? "",
      scopes: CompletionLearning.scopes(
        commandPath: try XCTUnwrap(typing["commandPath"] as? [String])),
      store: store, now: 1000)
    XCTAssertEqual(ranked.first?.value, "--amend", "別位置で覚えた --amend が元順を追い越して先頭へ")
  }
}
