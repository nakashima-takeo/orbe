import XCTest

@testable import Orbe

/// 補完の学習ランキング（頻度・recency・二層スコープ）の純関数を検証する。
/// engine も popup も不要でユニット完結する（`rank`・`record`・`score`・`scopes` が純関数）。
/// 頻度・recency・完全一致不可侵・ゼロ回帰の 4 点と、二層スコープ（門番なし・静的スコープ維持・
/// 除外・完全一致不可侵の動的版）を機械検証する。
final class CompletionLearningTests: XCTestCase {
  private let now: Double = 1_000_000
  /// 静的・動的が同値の最小スコープ（root コマンド 1 語のみのバッファ相当）。
  private let scopes = CompletionLearning.LearningScopes(staticScope: "git", dynamicScope: "git")

  private func choice(_ value: String, type: String? = "subcommand") -> CompletionChoice {
    CompletionChoice(value: value, description: "", insertValue: nil, type: type)
  }

  private func key(_ candidate: String, scope: String = "git") -> String {
    scope + CompletionLearning.separator + candidate
  }

  private func names(_ choices: [CompletionChoice]) -> [String] { choices.map(\.value) }

  // MARK: - ゴール1: よく使う候補が上（頻度）

  func testMoreFrequentRanksHigher() {
    // X を 2 回・Y を 1 回 record（同一 now）→ 空 query で [X, Y]。
    var store = LearningStore.empty
    store = XCTUnwrap2(
      CompletionLearning.record(
        scopes: scopes, candidate: "commit", type: "subcommand", now: now, into: store))
    store = XCTUnwrap2(
      CompletionLearning.record(
        scopes: scopes, candidate: "commit", type: "subcommand", now: now, into: store))
    store = XCTUnwrap2(
      CompletionLearning.record(
        scopes: scopes, candidate: "checkout", type: "subcommand", now: now, into: store))
    let ranked = CompletionLearning.rank(
      [choice("checkout"), choice("commit")], query: "", scopes: scopes, store: store, now: now)
    XCTAssertEqual(names(ranked), ["commit", "checkout"], "accept 回数が多い候補が上")
  }

  // MARK: - ゴール2: 最近使った候補が上（recency）

  func testMoreRecentRanksHigherAtSameCount() {
    // count=1 同士。X を古く・Y を新しく → [Y, X]。
    var store = LearningStore.empty
    store.entries[key("commit")] = LearningEntry(
      count: 1, lastUsed: now - CompletionLearning.halfLife * 4)
    store.entries[key("checkout")] = LearningEntry(count: 1, lastUsed: now)
    let ranked = CompletionLearning.rank(
      [choice("commit"), choice("checkout")], query: "", scopes: scopes, store: store, now: now)
    XCTAssertEqual(names(ranked), ["checkout", "commit"], "count 同数なら直近 accept が上")
  }

  // MARK: - ゴール3: 完全一致優先を壊さない

  func testExactMatchOutranksLearnedPrefix() {
    // query="co"。commit（前方一致・多用）を学習しても、co（完全一致・未学習）が上のまま。
    var store = LearningStore.empty
    for _ in 0..<50 {
      store = XCTUnwrap2(
        CompletionLearning.record(
          scopes: scopes, candidate: "commit", type: "subcommand", now: now, into: store))
    }
    let ranked = CompletionLearning.rank(
      [choice("commit"), choice("co")], query: "co", scopes: scopes, store: store, now: now)
    XCTAssertEqual(names(ranked), ["co", "commit"], "完全一致は学習スコアに関わらず前方一致より上")
  }

  // MARK: - M6: 完全一致不可侵（動的候補版）

  func testExactMatchOutranksLearnedDynamicCandidate() {
    // query="main"。feature-main（前方一致・高 count の動的候補）を学習しても、
    // main（完全一致・未学習）が上のまま。
    var store = LearningStore.empty
    for _ in 0..<50 {
      store = XCTUnwrap2(
        CompletionLearning.record(
          scopes: scopes, candidate: "main-backup", type: nil, now: now, into: store))
    }
    let ranked = CompletionLearning.rank(
      [choice("main-backup", type: nil), choice("main", type: nil)], query: "main",
      scopes: scopes, store: store, now: now)
    XCTAssertEqual(names(ranked), ["main", "main-backup"], "完全一致は動的学習スコアに関わらず上")
  }

  // MARK: - ゴール4: 学習ゼロ回帰（入力順を保持）

  func testEmptyStorePreservesInputOrder() {
    let input = [choice("bench"), choice("build"), choice("doc")]
    let ranked = CompletionLearning.rank(input, query: "", scopes: scopes, store: .empty, now: now)
    XCTAssertEqual(names(ranked), names(input), "空ストアは engine 元順を安定保持（回帰なし）")
  }

  func testEmptyStoreWithQueryPreservesInputOrder() {
    // matchQuality 同値（全前方一致）でも学習ゼロなら元順を保つ。
    let input = [choice("commit"), choice("config"), choice("checkout")]
    let ranked = CompletionLearning.rank(input, query: "c", scopes: scopes, store: .empty, now: now)
    XCTAssertEqual(names(ranked), names(input), "同一致品質・学習ゼロは元順を安定保持")
  }

  // MARK: - M1: 門番撤廃（動的候補も記録される）

  func testRecordLearnsDynamicCandidates() {
    // type nil / file / folder / arg も記録される（v1 の type 門番を撤廃）。
    for type in [nil, "file", "folder", "arg"] {
      let store = CompletionLearning.record(
        scopes: scopes, candidate: "feature-x", type: type, now: now, into: .empty)
      XCTAssertNotNil(store, "動的候補（type=\(type ?? "nil")）も記録される")
      XCTAssertNotNil(
        store?.entries[key("feature-x")], "動的候補のキーは dynamicScope（root 1語）に載る")
    }
  }

  func testRecordLearnsSubcommandAndOption() {
    XCTAssertNotNil(
      CompletionLearning.record(
        scopes: scopes, candidate: "commit", type: "subcommand", now: now, into: .empty))
    XCTAssertNotNil(
      CompletionLearning.record(
        scopes: scopes, candidate: "--verbose", type: "option", now: now, into: .empty))
  }

  // MARK: - M3: 静的候補は現行スコープ（全プレフィックス）を維持

  func testStaticCandidateKeyedByFullPrefixNotSharedAcrossSubcommands() {
    // `git commit --v` で学習した option --verbose のキーは staticScope "git commit"。
    let commitScopes = CompletionLearning.scopes(buffer: "git commit --v", replaceStart: 11)
    let store = XCTUnwrap2(
      CompletionLearning.record(
        scopes: commitScopes, candidate: "--verbose", type: "option", now: now, into: .empty))
    XCTAssertNotNil(store.entries[key("--verbose", scope: "git commit")], "キーは全プレフィックス")
    XCTAssertNil(store.entries[key("--verbose")], "dynamicScope（git）側には記録されない")
    // `git rebase ` の staticScope は "git rebase" ≠ "git commit" → 静的学習は共有されない。
    let rebaseScopes = CompletionLearning.scopes(buffer: "git rebase ", replaceStart: 11)
    XCTAssertNil(
      store.entries[
        CompletionLearning.scope(for: "option", in: rebaseScopes)
          + CompletionLearning.separator + "--verbose"],
      "サブコマンド間で静的学習は共有されない")
  }

  func testDynamicCandidateSharedAcrossSubcommands() {
    // `git switch fea` で学習したブランチのキーは dynamicScope "git" → `git rebase ` からも引ける。
    let switchScopes = CompletionLearning.scopes(buffer: "git switch fea", replaceStart: 11)
    let store = XCTUnwrap2(
      CompletionLearning.record(
        scopes: switchScopes, candidate: "feature-x", type: nil, now: now, into: .empty))
    XCTAssertNotNil(store.entries[key("feature-x")], "動的キーは root 1語スコープ")
    let rebaseScopes = CompletionLearning.scopes(buffer: "git rebase ", replaceStart: 11)
    XCTAssertNotNil(
      store.entries[
        CompletionLearning.scope(for: nil, in: rebaseScopes)
          + CompletionLearning.separator + "feature-x"],
      "別サブコマンドの dynamicScope から同じキーが引ける")
  }

  // MARK: - M4: 相対ナビゲーションの除外

  func testRecordExcludesRelativeNavigation() {
    for candidate in ["../", "./", "..", "."] {
      XCTAssertNil(
        CompletionLearning.record(
          scopes: scopes, candidate: candidate, type: "folder", now: now, into: .empty),
        "相対ナビゲーション（\(candidate)）は記録しない")
    }
  }

  // MARK: - score（frecency 単調性）

  func testScoreDecaysOverTime() {
    let e = LearningEntry(count: 4, lastUsed: now)
    XCTAssertEqual(CompletionLearning.score(e, now: now), 4, accuracy: 1e-9, "Δt=0 は count そのまま")
    XCTAssertEqual(
      CompletionLearning.score(e, now: now + CompletionLearning.halfLife), 2, accuracy: 1e-6,
      "半減期経過で半分")
  }

  // MARK: - scopes（二層スコープの導出）

  func testScopesDerivation() {
    // "git commit --v" の現在トークン "--v"（replaceStart=11）→ static="git commit"・dynamic="git"。
    XCTAssertEqual(
      CompletionLearning.scopes(buffer: "git commit --v", replaceStart: 11),
      CompletionLearning.LearningScopes(staticScope: "git commit", dynamicScope: "git"))
  }

  func testScopesLowercaseAndCollapseSpaces() {
    // 連続空白は 1 個へ・lowercase する（dynamic も同じ正規化を通した先頭 1 語）。
    XCTAssertEqual(
      CompletionLearning.scopes(buffer: "GIT   Commit  x", replaceStart: 14),
      CompletionLearning.LearningScopes(staticScope: "git commit", dynamicScope: "git"))
  }

  func testScopesEmptyForCommandName() {
    // コマンド名自体の補完（"gi" の現在トークンが先頭）は両層とも空 scope
    // （buffer 先頭は入力途中の query 自身。キーにすると打鍵ごとに散る）。
    XCTAssertEqual(
      CompletionLearning.scopes(buffer: "gi", replaceStart: 0),
      CompletionLearning.LearningScopes(staticScope: "", dynamicScope: ""))
  }

  func testScopeSelectionByType() {
    let two = CompletionLearning.LearningScopes(staticScope: "git commit", dynamicScope: "git")
    XCTAssertEqual(CompletionLearning.scope(for: "subcommand", in: two), "git commit")
    XCTAssertEqual(CompletionLearning.scope(for: "option", in: two), "git commit")
    for type in [nil, "file", "folder", "arg"] {
      XCTAssertEqual(CompletionLearning.scope(for: type, in: two), "git", "動的候補は root 1語")
    }
  }

  // MARK: - maxEntries 退避（frecency 最小を落とす）

  func testEvictsLowestFrecencyWhenOverCapacity() {
    var store = LearningStore.empty
    // 上限まで新しめのエントリで埋める。
    for i in 0..<CompletionLearning.maxEntries {
      store.entries[key("c\(i)")] = LearningEntry(count: 5, lastUsed: now)
    }
    // 古くて count も少ない = 最低 frecency のエントリを 1 件差し込む。
    let weak = key("weak")
    store.entries[weak] = LearningEntry(count: 1, lastUsed: now - CompletionLearning.halfLife * 10)
    XCTAssertEqual(store.entries.count, CompletionLearning.maxEntries + 1)
    // 新規 record で上限超過 → frecency 最小（weak）が退避される。
    let next = XCTUnwrap2(
      CompletionLearning.record(
        scopes: scopes, candidate: "fresh", type: "subcommand", now: now, into: store))
    XCTAssertEqual(next.entries.count, CompletionLearning.maxEntries, "上限に収まる")
    XCTAssertNil(next.entries[weak], "frecency 最小のエントリが退避される")
    XCTAssertNotNil(next.entries[key("fresh")], "新規は残る")
  }

  // MARK: - 永続（round-trip・fileURLOverride）

  func testPersistenceRoundTrip() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("CompletionLearningTests-\(UUID().uuidString).json")
    CompletionLearning.fileURLOverride = url
    defer {
      try? FileManager.default.removeItem(at: url)
      CompletionLearning.fileURLOverride = nil
    }
    var store = LearningStore.empty
    store.entries[key("commit")] = LearningEntry(count: 3, lastUsed: now)
    CompletionLearning.save(store)
    XCTAssertEqual(CompletionLearning.load(), store, "保存→読込で一致")
  }

  func testLoadMissingFileReturnsEmpty() {
    CompletionLearning.fileURLOverride = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("CompletionLearningTests-missing-\(UUID().uuidString).json")
    defer { CompletionLearning.fileURLOverride = nil }
    XCTAssertEqual(CompletionLearning.load(), .empty, "欠落は空ストア（新規ユーザ回帰なし）")
  }

  /// XCTUnwrap は throws で純関数チェーンに混ぜにくいため、record（除外候補なら nil）の非 nil を畳む小道具。
  private func XCTUnwrap2(
    _ store: LearningStore?, file: StaticString = #filePath, line: UInt = #line
  )
    -> LearningStore
  {
    guard let store else {
      XCTFail("record が nil を返した（記録されるはず）", file: file, line: line)
      return .empty
    }
    return store
  }
}
