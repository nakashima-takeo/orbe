import JavaScriptCore
import XCTest

@testable import Orbe

/// 補完エンジン（prebuilt JS バンドル）の契約を検証する。JSC 同期橋渡し
/// （__orbe_exec 同期化 → microtask drain で __orbe_result 確定）・engine 由来候補・
/// engine→host 学習の結線（実バンドルの type/候補で record・rank が発火する）を担保する。
final class CompletionEngineTests: OrbeTestCase {
  /// commit 済み `app/completion-engine.js` を JSContext に読み、stub の native 関数を注入する。
  /// CompletionEngine.swift の `installNativeBridge` と同じ顔ぶれ（__orbe_exec / __orbe_access /
  /// __orbe_readdir / __orbe_home）を揃え、同じ駆動契約（__orbe_buffer/__orbe_cwd → __orbe_run()
  /// → microtask drain → __orbe_result）で候補を取る。JS エンジンの契約を host から独立に検証する。
  private struct EngineHarness {
    let ctx: JSContext
    init?(
      exec: @escaping (String) -> String,
      access: @escaping (String) -> Bool = { _ in true },
      readdir: @escaping (String) -> [(name: String, isDirectory: Bool)] = { _ in [] }
    ) {
      // Tests/OrbeTests/CompletionEngineTests.swift → リポジトリ root → app/completion-engine.js
      let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      let bundle = root.appendingPathComponent("app/completion-engine.js")
      guard let source = try? String(contentsOf: bundle, encoding: .utf8), let ctx = JSContext()
      else { return nil }
      ctx.exceptionHandler = { _, exc in XCTFail("JS exception: \(exc?.toString() ?? "?")") }
      let execBlock: @convention(block) (String, String) -> String = { command, _ in exec(command) }
      ctx.setObject(execBlock, forKeyedSubscript: "__orbe_exec" as NSString)
      let accessBlock: @convention(block) (String) -> Bool = { access($0) }
      ctx.setObject(accessBlock, forKeyedSubscript: "__orbe_access" as NSString)
      let readdirBlock: @convention(block) (String) -> [[String: Any]] = { dir in
        readdir(dir).map { ["name": $0.name, "isDirectory": $0.isDirectory] }
      }
      ctx.setObject(readdirBlock, forKeyedSubscript: "__orbe_readdir" as NSString)
      ctx.setObject("/tmp", forKeyedSubscript: "__orbe_home" as NSString)
      ctx.evaluateScript(source)
      self.ctx = ctx
    }

    func complete(_ buffer: String, cwd: String = "/tmp") -> [String: Any] {
      ctx.setObject(buffer, forKeyedSubscript: "__orbe_buffer" as NSString)
      ctx.setObject(cwd, forKeyedSubscript: "__orbe_cwd" as NSString)
      ctx.evaluateScript("__orbe_run()")
      guard let v = ctx.objectForKeyedSubscript("__orbe_result"), !v.isNull,
        let data = v.toString()?.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return [:] }
      return obj
    }
  }

  private func names(_ result: [String: Any]) -> [String] {
    (result["suggestions"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
  }

  /// 候補 name の `type` フィールド（nil = engine が型を付けていない）。
  private func type(_ result: [String: Any], name: String) -> String? {
    (result["suggestions"] as? [[String: Any]])?
      .first { $0["name"] as? String == name }?["type"] as? String
  }

  func testEnginePrefixCommandCandidates() throws {
    let h = try XCTUnwrap(EngineHarness { _ in "" }, "app/completion-engine.js が読めること")
    let result = h.complete("gi")
    XCTAssertTrue(names(result).contains("git"), "第1トークン補完が engine 由来で出る")
    XCTAssertEqual(result["replaceLength"] as? Int, 2, "現在トークン 'gi' の文字数を返す")
  }

  func testEngineSubcommandCandidates() throws {
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    XCTAssertTrue(names(h.complete("git ")).contains("commit"), "withfig git spec 由来のサブコマンド")
    let ch = names(h.complete("git ch"))
    XCTAssertTrue(ch.contains("checkout"), "プレフィックス絞り込み")
    XCTAssertFalse(ch.contains("commit"), "プレフィックス不一致は除外")
  }

  func testEngineTagsSubcommandAndOptionType() throws {
    // 実バンドルが subcommand/option 候補へ構造的 type を確実に付ける（二層スコープの層選びの前提）。
    // spec は subcommand/option に type を書かないため、ランタイム出力層で起源型を焼く必要がある。
    // これが nil だと静的候補が動的層（root 1語）へ記録され、サブコマンド間の誤爆防止が壊れる。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    XCTAssertEqual(
      type(h.complete("git "), name: "commit"), "subcommand", "subcommand 起源に type が付く")
    XCTAssertEqual(
      type(h.complete("git commit --v"), name: "--verbose"), "option", "option 起源に type が付く")
  }

  // MARK: - 解析事実の payload（host はこれを再導出しない）

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

  func testEngineSubcommandFeedsLearning() throws {
    // 本番経路の end-to-end 実証: 実 engine が返す subcommand の type で record が発火し（no-op でない）、
    // rank がその候補を引き上げる。engine→host 学習の結線を突く（差し戻しバグの直結ケース）。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    let commitType = type(h.complete("git "), name: "commit")
    let scopes = CompletionLearning.scopes(commandPath: ["git"])
    let store = try XCTUnwrap(
      CompletionLearning.record(
        scopes: scopes, candidate: "commit", type: commitType, now: 1000, into: .empty),
      "実 engine の subcommand type で record が発火する（本番で no-op にならない）")
    let ranked = CompletionLearning.rank(
      [
        CompletionChoice(value: "checkout", description: "", insertValue: nil, type: "subcommand"),
        CompletionChoice(value: "commit", description: "", insertValue: nil, type: "subcommand"),
      ], query: "", scopes: scopes, store: store, now: 1000)
    XCTAssertEqual(ranked.map(\.value), ["commit", "checkout"], "学習した commit が上へ")
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

  func testEngineDynamicCandidateLearningSharedAcrossSubcommands() throws {
    // 実バンドルの generator が返す type 無しブランチ候補を `git switch ` で record し、
    // **別バッファ** `git rebase ` の実候補に対して rank すると当該ブランチが engine 元順を追い越して
    // 先頭に上がる＝動的候補の学習が root コマンド 1 語スコープでサブコマンド間共有される。
    let h = try XCTUnwrap(EngineHarness { _ in "* main\n  feature-x\n" })

    // accept 経路: `git switch ` の実候補から type 無しのブランチ候補を取り、本番の scopes＋record で記録。
    let switchResult = h.complete("git switch ")
    XCTAssertTrue(names(switchResult).contains("feature-x"), "generator 由来のブランチ候補が出る")
    let branchType = type(switchResult, name: "feature-x")
    XCTAssertNil(branchType, "generator 出力のブランチ候補は type 無し（動的候補）")
    let store = try XCTUnwrap(
      CompletionLearning.record(
        scopes: CompletionLearning.scopes(commandPath: ["git", "switch"]),
        candidate: "feature-x", type: branchType, now: 1000, into: .empty),
      "動的候補の record が発火する（v1 の type 門番を撤廃）")

    // update 経路: 別バッファ `git rebase ` の実候補を rank → 学習済みブランチが先頭へ。
    let rebaseResult = h.complete("git rebase ")
    let choices = (rebaseResult["suggestions"] as? [[String: Any]])?.compactMap { s in
      (s["name"] as? String).map {
        CompletionChoice(
          value: $0, description: "", insertValue: s["insertValue"] as? String,
          type: s["type"] as? String)
      }
    }
    let rebaseChoices = try XCTUnwrap(choices)
    XCTAssertTrue(rebaseChoices.contains { $0.value == "feature-x" }, "rebase でも同ブランチ候補が出る")
    XCTAssertNotEqual(rebaseChoices.first?.value, "feature-x", "engine 元順では先頭でない（追い越しの前提）")
    let ranked = CompletionLearning.rank(
      rebaseChoices, query: "",
      scopes: CompletionLearning.scopes(commandPath: ["git", "rebase"]),
      store: store, now: 1000)
    XCTAssertEqual(ranked.first?.value, "feature-x", "学習したブランチがサブコマンドを跨いで先頭に上がる")
  }

  func testEngineCuratedCommandNotInHandWrittenSpec() throws {
    // 手書き spec に無かった curated コマンドでも候補が出る＝engine 由来である証左。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    XCTAssertTrue(names(h.complete("docker ")).contains("build"))
    XCTAssertTrue(names(h.complete("cargo ")).contains("build"))
  }

  func testEngineNewSpecsProduceCandidates() throws {
    // 後から追加した 10 spec が実バンドルで候補を出す。arg 主体のコマンド
    // （mkdir/open/touch/xcodebuild/code）はオプション位置 `-`、`source`（純 arg）は
    // ファイル列挙の stub で判定する。
    let h = try XCTUnwrap(
      EngineHarness(
        exec: { _ in "script.sh\n" },
        readdir: { _ in [(name: "script.sh", isDirectory: false)] }))
    XCTAssertTrue(names(h.complete("deno ")).contains("run"), "deno: 上流 spec のサブコマンド")
    XCTAssertTrue(names(h.complete("volta ")).contains("install"), "volta: 上流 spec のサブコマンド")
    XCTAssertFalse(names(h.complete("code -")).isEmpty, "code: オプション位置で候補が出る")
    XCTAssertFalse(names(h.complete("mkdir -")).isEmpty, "mkdir: オプション位置で候補が出る")
    XCTAssertFalse(names(h.complete("xcodebuild -")).isEmpty, "xcodebuild: オプション位置で候補が出る")
    XCTAssertFalse(names(h.complete("open -")).isEmpty, "open: オプション位置で候補が出る")
    XCTAssertFalse(names(h.complete("touch -")).isEmpty, "touch: オプション位置で候補が出る")
    XCTAssertFalse(names(h.complete("source ")).isEmpty, "source: ファイル列挙で候補が出る")
  }

  func testEngineSelfAuthoredSpecs() throws {
    // 自家 spec（上流に無い claude/codex）が実バンドルで候補を出す。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    let claude = h.complete("claude ")
    XCTAssertTrue(names(claude).contains("mcp"), "claude: 自家 spec のサブコマンド")
    XCTAssertEqual(type(claude, name: "mcp"), "subcommand", "自家 spec にも起源型が焼かれる")
    XCTAssertTrue(names(h.complete("codex ")).contains("exec"), "codex: 自家 spec のサブコマンド")
    XCTAssertTrue(names(h.complete("claude --")).contains("--model"), "claude: オプションも出る")
  }

  func testEngineGeneratorUsesNativeExec() throws {
    // generator のシェル実行は __orbe_exec（Swift 注入）に委ねられる。
    // git ブランチ列挙を stub し、その出力が候補へ反映されることを確認する。
    var seenCommands: [String] = []
    let h = try XCTUnwrap(
      EngineHarness { command in
        seenCommands.append(command)
        return "* main\n  feature-x\n"
      })
    let result = h.complete("git checkout ")
    XCTAssertTrue(seenCommands.contains { $0.contains("git") }, "generator が native exec を呼ぶ")
    XCTAssertTrue(names(result).contains("feature-x"), "exec 出力が候補に反映される")
  }

  // MARK: - シェルインジェクション（打鍵だけで任意コード実行に至らないこと）

  func testEngineNeverPutsPathTokensOnAShellCommandLine() throws {
    // ディレクトリ名は外部から与えられる文字列。これがシェルのコマンド行に載ると、引用を
    // 一段誤るだけで `$(…)` が展開されて任意コード実行になる（悪意ある名前のディレクトリを
    // 含む repo を配布し、被害者がその配下でパスを打鍵するだけで発火する）。
    // パスの到達確認・列挙は native の __orbe_access / __orbe_readdir が担い、シェルは
    // 一切経由しない——その契約を、payload が exec のコマンド行へ現れないことで固定する。
    // 空白を含まない payload を使う。lexer は空白でトークンを割るので、空白入りだと
    // resolveCwd へ届く前に千切れてしまい、塞いだはずの経路を通らずテストが素通りする。
    let payload = "$(id)"
    var seenCommands: [String] = []
    var seenAccess: [String] = []
    let h = try XCTUnwrap(
      EngineHarness(
        exec: { command in
          seenCommands.append(command)
          return ""
        },
        access: { path in
          seenAccess.append(path)
          return true
        },
        readdir: { _ in [(name: "note.txt", isDirectory: false)] }))

    _ = h.complete("ls \(payload)/")

    XCTAssertTrue(
      seenAccess.contains { $0.contains(payload) },
      "到達確認は native access に渡る（この経路自体は残る）")
    XCTAssertFalse(
      seenCommands.contains { $0.contains(payload) },
      "パストークンがシェルのコマンド行へ載らない")
  }

  func testEngineQuotesGeneratorArgumentsAsSingleWords() throws {
    // generator は任意コマンドを走らせる仕様なのでシェルが要る。そこへ載る引数は spec と
    // 打鍵内容に由来するため、単一引用で 1 語に閉じ込める必要がある。`docker pull` の
    // dockerHubSearch generator は打鍵中のトークンをそのまま引数に渡す（`["docker","search",
    // tokens.at(-1), …]`）ので、これを踏み台にして「引数が引用の外へ出ないこと」を固定する。
    // payload に空白・`;` を含めないのは、lexer がそこでトークンとコマンドを割ってしまい、
    // generator へ届く前に千切れるため（届かないと引用の検証にならない）。
    let payload = "x$(id)y"
    var seenCommands: [String] = []
    let h = try XCTUnwrap(
      EngineHarness { command in
        seenCommands.append(command)
        return ""
      })

    _ = h.complete("docker pull \(payload)")

    let carrying = seenCommands.filter { $0.contains(payload) }
    XCTAssertFalse(
      carrying.isEmpty,
      "打鍵内容が generator の引数として実際にコマンド行へ載ること（この前提が崩れるとテストが空回りする）")
    for command in carrying {
      XCTAssertTrue(
        command.contains("'\(payload)'"),
        "打鍵内容は単一引用で 1 語に閉じられる（引用の外に出るとコマンド区切りになる）: \(command)")
    }
  }

  func testEngineEscapesShellMetacharactersInInsertedPaths() throws {
    // 候補を確定するとその文字列はユーザーのバッファへ入り、Enter で**ユーザー自身の**シェルが
    // 解釈する。悪意あるファイル名がそのまま入ると、確定→Enter で任意コード実行になる。
    let h = try XCTUnwrap(
      EngineHarness(
        exec: { _ in "" },
        readdir: { _ in [(name: "$(id).txt", isDirectory: false)] }))

    let result = h.complete("source ./")
    let inserted = (result["suggestions"] as? [[String: Any]] ?? [])
      .compactMap { $0["insertValue"] as? String }
      .filter { $0.contains("id") }

    XCTAssertFalse(inserted.isEmpty, "候補が出ること（前提）")
    for value in inserted {
      XCTAssertFalse(
        value.contains("$(") && !value.contains("\\$"),
        "挿入値の `$` がエスケープされずに残らない: \(value)")
    }
  }

  func testEngineExactMatchRanksFirst() throws {
    // folders 生成（`cd` は `ls -1ApL` でディレクトリ列挙）で、query に完全一致する
    // ディレクトリ名が接尾辞付き（前方一致）より前に来る＝engine の一致品質キーが効く
    // （報告バグの直結ケース）。列挙は接尾辞付きを先に返し、sort が完全一致を引き上げる。
    let h = try XCTUnwrap(EngineHarness { _ in "orbe__asdf/\norbe/\n" })
    let ordered = names(h.complete("cd orbe"))
    let exact = try XCTUnwrap(ordered.firstIndex(of: "orbe"), "完全一致候補が出る")
    let suffixed = try XCTUnwrap(ordered.firstIndex(of: "orbe__asdf"), "接尾辞付き候補が出る")
    XCTAssertLessThan(exact, suffixed, "完全一致 orbe が接尾辞付き orbe__asdf より前")
  }

  func testEngineShorterNameRanksFirstAtSameQuality() throws {
    // 完全一致が無く前方一致同士なら、名前が短い候補を先に返す（一致品質タイの副次キー）。
    let h = try XCTUnwrap(EngineHarness { _ in "abcdef/\nabc/\n" })
    let ordered = names(h.complete("cd ab"))
    let short = try XCTUnwrap(ordered.firstIndex(of: "abc"), "短い候補が出る")
    let long = try XCTUnwrap(ordered.firstIndex(of: "abcdef"), "長い候補が出る")
    XCTAssertLessThan(short, long, "同一致品質では短い名前 abc が先")
  }

  func testEngineEmptyQueryPreservesEnumerationOrder() throws {
    // 空 query（`cargo ` の全サブコマンド列挙）は priority 同値（curated spec は既定 50）。
    // 名前長キーは query 入力時のみ効くため、列挙は spec 定義順を安定保持し名前長で崩れない。
    // curated 順は bench→…→doc。名前長順なら doc(3) が bench(5) より前へ来てしまう＝回帰検知。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    let ordered = names(h.complete("cargo "))
    let bench = try XCTUnwrap(ordered.firstIndex(of: "bench"), "bench 候補が出る")
    let doc = try XCTUnwrap(ordered.firstIndex(of: "doc"), "doc 候補が出る")
    XCTAssertLessThan(bench, doc, "空 query は spec 定義順を保持（bench が doc より前・名前長で並べ替えない）")
  }

  func testEngineUnknownCommandEmpty() throws {
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    let result = h.complete("frobnicate ")
    XCTAssertTrue(names(result).isEmpty, "未収録コマンドは候補ゼロ")
    XCTAssertEqual(result["query"] as? String, "", "何も確定していないので照合トークンは既定値")
    XCTAssertEqual(result["commandPath"] as? [String], [], "同じく確定コマンド列も既定値")
  }

  func testEngineEmptyBufferNoCandidates() throws {
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    let result = h.complete("")
    XCTAssertTrue(names(result).isEmpty, "空 buffer では候補を出さない")
    XCTAssertEqual(result["query"] as? String, "", "何も確定していないので照合トークンは既定値")
    XCTAssertEqual(result["commandPath"] as? [String], [], "同じく確定コマンド列も既定値")
  }

  func testEngineBundleAbsentDegradesGracefully() {
    // 同梱物が無い状態（ハーネスが BundledResources.root を管理下の空ディレクトリへ向けている）では
    // engine が未ロードになる。候補ゼロで返りクラッシュしないことを確かめる。
    XCTAssertNil(CompletionEngine.bundlePath, "同梱物の探索根に completion-engine.js が無い")
    let exp = expectation(description: "suggestions returns")
    CompletionEngine.shared.suggestions(buffer: "git ", cursor: 4, cwd: "/tmp") { result in
      XCTAssertTrue(result.choices.isEmpty)
      XCTAssertEqual(result.query, "", "解析していないので照合トークンは既定値")
      XCTAssertEqual(result.commandPath, [], "同じく確定コマンド列も既定値")
      exp.fulfill()
    }
    wait(for: [exp], timeout: 2)
  }
}
