import Foundation

/// 補完候補の学習ランキング（頻度・recency）。engine(JS) は純関数のまま据え置き、host が
/// `CompletionList.displayOrdered` の直前に学習キーで安定再ソートする。accept された候補の
/// `count`・`lastUsed` を frecency スカラへ合成し、一致品質の下・engine 元順の上に差す。
/// 完全一致優先（matchQuality が最上位キー）は不可侵。
///
/// 学習対象は accept された全候補で、スコープを候補種別で二層化する:
/// - 静的候補（`type` = subcommand / option）: 直前までの全プレフィックス（過剰スコープ側・誤爆防止）。
/// - 動的候補（それ以外全部 = type 無し・file・folder・arg 等）: root コマンド 1 語
///   （`git switch` で覚えたブランチを `git rebase` でも引けるようサブコマンド間で共有する）。
/// 導出は `scopes(buffer:replaceStart:)`＋`scope(for:in:)` に集約し、record と rank が必ず共有する
/// （非対称を構造的に排除する）。`../` `./` 等の相対ナビゲーションは記録から除外する。
///
/// 純関数（`scopes`・`record`・`score`・`rank`）がテストの主対象。永続は自前 JSON
/// （`SettingsPersistence` 同型・`ORBE_STATE_DIR` 隔離規約に自動追従）。accept ごとに書くため
/// settings.json とは別ファイル。`shared` は main 限定アクセス（update / accept 経路とも main）。

/// キー毎の学習信号。頻度（count 累積）と recency（lastUsed）を O(1) で持つ。
struct LearningEntry: Codable, Equatable {
  var count: Int
  var lastUsed: Double  // epoch 秒
}

/// 学習ストア（`scope<sep>candidate` → entry）。version 付きの Codable マップ。
struct LearningStore: Codable, Equatable {
  var version: Int
  var entries: [String: LearningEntry]

  static let empty = LearningStore(version: 1, entries: [:])
}

final class CompletionLearning {
  /// プロセスで 1 度 load してメモリ保持。accept で更新→save＋メモリ反映。update の毎回 disk 読みはしない。
  static let shared = CompletionLearning()

  /// テスト用に保存先を差し替える（`SettingsPersistence.fileURLOverride` 踏襲）。本番は nil。
  static var fileURLOverride: URL?

  /// frecency の半減期（14 日）。この Δt 経過で score が半分になる。
  static let halfLife: Double = 14 * 24 * 60 * 60
  /// エントリ上限。超過時は書き込み時に frecency 最小を退避（LRU 的）。
  static let maxEntries = 2000
  /// scope と candidate の区切り（Unit Separator・生バッファに現れない）。
  static let separator = "\u{1f}"

  private var store: LearningStore

  private init() { store = Self.load() }

  // MARK: - main 経路のステートフル facade

  /// accept 経路で候補を記録する（除外候補〔`../` 等〕のみ no-op。それ以外は全て記録する）。
  func record(scopes: LearningScopes, candidate: String, type: String?, now: Double) {
    guard
      let updated = Self.record(
        scopes: scopes, candidate: candidate, type: type, now: now, into: store)
    else { return }
    store = updated
    Self.save(store)
  }

  /// update 経路で候補を学習キーで安定再ソートする。
  func rank(_ choices: [CompletionChoice], query: String, scopes: LearningScopes, now: Double)
    -> [CompletionChoice]
  {
    Self.rank(choices, query: query, scopes: scopes, store: store, now: now)
  }

  // MARK: - 純ロジック（テストの主対象）

  /// 二層スコープ（record と rank が唯一共有する導出結果）。
  /// - staticScope: 現在トークン直前までの全プレフィックス（subcommand/option 用・誤爆防止）。
  /// - dynamicScope: root コマンド 1 語（動的候補用・サブコマンド間で共有）。
  struct LearningScopes: Equatable {
    let staticScope: String
    let dynamicScope: String
  }

  /// 二層スコープの導出。staticScope は生バッファ `buffer[0..<replaceStart]` を
  /// 空白分割 → lowercase → 空白 1 個 join。dynamicScope はその先頭トークン
  /// （`replaceStart == 0`＝コマンド名自体の補完では ""——buffer 先頭は入力途中の query 自身で、
  /// キーにすると打鍵ごとに別キーへ散るため）。
  /// オフセットは scalar 単位（buffer 全体と揃える。NFD パスでずれないよう書記素にしない）。
  static func scopes(buffer: String, replaceStart: Int) -> LearningScopes {
    let chars = Array(buffer.unicodeScalars)
    let end = max(0, min(replaceStart, chars.count))
    let prefix = String(String.UnicodeScalarView(chars[0..<end]))
    let staticScope = prefix.split(separator: " ").map { $0.lowercased() }
      .joined(separator: " ")
    return LearningScopes(
      staticScope: staticScope,
      dynamicScope: staticScope.split(separator: " ").first.map(String.init) ?? "")
  }

  /// type から層を選ぶ（record / rank 共用の唯一の分岐点）。
  static func scope(for type: String?, in scopes: LearningScopes) -> String {
    (type == "subcommand" || type == "option") ? scopes.staticScope : scopes.dynamicScope
  }

  /// 記録から除外する候補値（相対ナビゲーション。学習しても並びを汚すだけで益が無い）。
  /// engine の folder 候補は末尾 `/` 付きだが、素の形が来ても弾けるよう 4 値で守る。
  private static let excludedCandidates: Set<String> = ["../", "./", "..", "."]

  /// 候補を記録した新ストアを返す。除外候補（`../` 等）のみ no-op で nil。
  /// 超過時は frecency 最小のエントリを退避（decay で古く使われないキーが自然に沈む）。
  static func record(
    scopes: LearningScopes, candidate: String, type: String?, now: Double, into store: LearningStore
  ) -> LearningStore? {
    guard !excludedCandidates.contains(candidate) else { return nil }
    var next = store
    let key = scope(for: type, in: scopes) + separator + candidate
    var entry = next.entries[key] ?? LearningEntry(count: 0, lastUsed: now)
    entry.count += 1
    entry.lastUsed = now
    next.entries[key] = entry
    // 超過時は frecency 最小を退避（decay で古く使われないキーが自然に沈む）。ただし今 record した
    // キー自身は「使われた瞬間」なので退避対象から除外する（accept が無効化されないよう）。
    while next.entries.count > maxEntries {
      guard
        let victim = next.entries
          .filter({ $0.key != key })
          .min(by: { score($0.value, now: now) < score($1.value, now: now) })?.key
      else { break }
      next.entries.removeValue(forKey: victim)
    }
    return next
  }

  /// frecency スコア。頻度（count）を recency の指数減衰で割り引く（`count * 2^(-Δt/halfLife)`）。
  static func score(_ e: LearningEntry, now: Double) -> Double {
    Double(e.count) * exp(-log(2.0) * (now - e.lastUsed) / halfLife)
  }

  /// query との一致品質。完全一致=2 > 前方一致=1 > 部分一致/その他=0。空 query は全候補 0。
  /// `suggestion.ts` の matchQuality と同義（lowercase・folder の末尾 `/` を剥がして比較）。
  static func matchQuality(_ name: String, _ query: String) -> Int {
    guard !query.isEmpty else { return 0 }
    var n = name.lowercased()
    if n.hasSuffix("/") { n.removeLast() }
    let p = query.lowercased()
    if n == p { return 2 }
    if n.hasPrefix(p) { return 1 }
    return 0
  }

  /// ソート用の 1 行（各 choice に付ける並びキー）。origIndex は安定化の最終タイブレーク。
  private struct Ranked {
    let matchQuality: Int
    let learnedScore: Double
    let origIndex: Int
    let choice: CompletionChoice
  }

  /// 学習キーで安定再ソートする。優先度順に matchQuality 降順 → learnedScore 降順 → engine 元順。
  /// learnedScore は候補ごとに `scope(for:in:)` で層を選んでキーを引き、有れば score、無ければ 0。
  /// origIndex を最終タイブレークにして安定化する（Swift の sort は不安定・ゼロ回帰と完全一致不可侵の要）。
  static func rank(
    _ choices: [CompletionChoice], query: String, scopes: LearningScopes, store: LearningStore,
    now: Double
  ) -> [CompletionChoice] {
    choices.enumerated()
      .map { index, choice -> Ranked in
        let learned =
          store.entries[scope(for: choice.type, in: scopes) + separator + choice.value]
          .map { score($0, now: now) } ?? 0
        return Ranked(
          matchQuality: matchQuality(choice.value, query), learnedScore: learned,
          origIndex: index, choice: choice)
      }
      .sorted { a, b in
        if a.matchQuality != b.matchQuality { return a.matchQuality > b.matchQuality }
        if a.learnedScore != b.learnedScore { return a.learnedScore > b.learnedScore }
        return a.origIndex < b.origIndex
      }
      .map(\.choice)
  }

  // MARK: - 永続 facade（atomic・pretty+sortedKeys）

  static var fileURL: URL? {
    if let override = fileURLOverride { return override }
    return StateDir.base()?.appendingPathComponent("completion-learning.json")
  }

  /// 読み込み。欠落・壊れは空ストア（新規ユーザ・データ無しは現状の並びと完全一致）。
  static func load() -> LearningStore {
    guard let url = fileURL, let data = try? Data(contentsOf: url),
      let file = try? JSONDecoder().decode(LearningStore.self, from: data)
    else { return .empty }
    return file
  }

  static func save(_ store: LearningStore) {
    guard let url = fileURL else { return }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(store) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
