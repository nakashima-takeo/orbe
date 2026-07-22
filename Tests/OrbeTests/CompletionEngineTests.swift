import JavaScriptCore
import XCTest

@testable import Orbe

/// 補完エンジン（prebuilt JS バンドル）の契約を検証する。JSC 同期橋渡し
/// （__orbe_exec 同期化 → microtask drain で __orbe_result 確定）・engine 由来候補・
/// engine→host 学習の結線（実バンドルの type/候補で record・rank が発火する）を担保する。
final class CompletionEngineTests: XCTestCase {
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

  func testEngineSubcommandFeedsLearning() throws {
    // 本番経路の end-to-end 実証: 実 engine が返す subcommand の type で record が発火し（no-op でない）、
    // rank がその候補を引き上げる。engine→host 学習の結線を突く（差し戻しバグの直結ケース）。
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    let commitType = type(h.complete("git "), name: "commit")
    let scopes = CompletionLearning.scopes(buffer: "git ", replaceStart: 4)
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
        scopes: CompletionLearning.scopes(buffer: "git switch ", replaceStart: 11),
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
      scopes: CompletionLearning.scopes(buffer: "git rebase ", replaceStart: 11),
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
    XCTAssertTrue(names(h.complete("frobnicate ")).isEmpty, "未収録コマンドは候補ゼロ")
  }

  func testEngineEmptyBufferNoCandidates() throws {
    let h = try XCTUnwrap(EngineHarness { _ in "" })
    XCTAssertTrue(names(h.complete("")).isEmpty, "空 buffer では候補を出さない")
  }

  func testEngineBundleAbsentDegradesGracefully() {
    // `swift test` は .app バンドル無し → engine 未ロード。候補ゼロで返りクラッシュしない。
    XCTAssertNil(CompletionEngine.bundlePath, "テスト実行体にはバンドルが無い")
    let exp = expectation(description: "suggestions returns")
    CompletionEngine.shared.suggestions(buffer: "git ", cursor: 4, cwd: "/tmp") { result in
      XCTAssertTrue(result.choices.isEmpty)
      exp.fulfill()
    }
    wait(for: [exp], timeout: 2)
  }
}
