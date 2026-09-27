import Foundation
import os

/// 文法ごとの規則（`GrammarRules`: 文法と highlights・injections・outline の問い合わせ）を、注入された queries の根から
/// 組む。根は `.app` なら `Contents/Resources`、`swift build` なら `.build/<config>` で、そこに SwiftPM の資源バンドル
/// `<bundleName>.bundle` が並ぶ。色の queries は文法のパッケージのバンドル、アウトラインの規則は Orbe のバンドル
/// （`outlineBundleName`）の `outline/` にある `Grammar.outlineFile`。根が nil・バンドル不在・queries が読めないときは
/// nil＝色無し（アウトラインの規則だけが無ければアウトライン無し）で、失敗として扱わない。結果はキャッシュする。複数の文書の
/// 構文の裏の仕事から同時に引かれるので、キャッシュは lock で守る（初めて使う文法はその場で組む）。
public final class LanguageRegistry: Sendable {
  private let queriesRoot: URL?
  private let cache = OSAllocatedUnfairLock(initialState: [Grammar: GrammarRules?]())

  /// アウトラインの規則を持つ資源バンドルの名前（SwiftPM の `<パッケージ名>_<ターゲット名>`）。
  static let outlineBundleName = "Orbe_OrbeEditorCore"

  public init(queriesRoot: URL?) {
    self.queriesRoot = queriesRoot
  }

  func rules(for language: SyntaxLanguage) -> GrammarRules? {
    rules(for: language.grammar)
  }

  /// injections が名乗る言語名（と fenced code の慣用名）から規則を引く。知らない名前は nil。
  func rules(forInjection name: String) -> GrammarRules? {
    Grammar(injectionName: name).flatMap { rules(for: $0) }
  }

  /// 組むのは lock の外——初めての文法を組む間、他の文書（main を含む）が別の文法を引くのを待たせない。同じ文法を同時に
  /// 組んだときは先に入れた方を使う。
  func rules(for grammar: Grammar) -> GrammarRules? {
    if let cached = cache.withLock({ $0[grammar] }) { return cached }
    let rules = load(grammar)
    return cache.withLock { cache in
      if let cached = cache[grammar] { return cached }
      cache[grammar] = rules
      return rules
    }
  }

  private func load(_ grammar: Grammar) -> GrammarRules? {
    guard let highlights = query(grammar.highlightFiles, for: grammar) else { return nil }
    let injections = grammar.injectionFile.flatMap { query([$0], for: grammar) }
    let outline = outlineURL(for: grammar).flatMap { try? Data(contentsOf: $0) }.flatMap {
      SyntaxQuery(language: grammar.language, source: $0)
    }
    return GrammarRules(
      grammar: grammar, highlights: highlights, injections: injections, outline: outline)
  }

  /// 複数ファイルを連結して 1 つの問い合わせに組む。どれか 1 つでも無ければ nil。
  private func query(_ files: [Grammar.QueryFile], for grammar: Grammar) -> SyntaxQuery? {
    var source = Data()
    for file in files {
      guard let url = url(of: file), let data = try? Data(contentsOf: url) else { return nil }
      source.append(data)
      source.append(0x0A)
    }
    return SyntaxQuery(language: grammar.language, source: source)
  }

  /// バンドル内の queries の所在。
  private func url(of file: Grammar.QueryFile) -> URL? {
    resource(file.name, directory: "queries", bundle: file.grammar.bundleName)
  }

  private func outlineURL(for grammar: Grammar) -> URL? {
    resource(grammar.outlineFile, directory: "outline", bundle: Self.outlineBundleName)
  }

  /// バンドル内のファイル。SwiftPM は `<bundle>/<dir>`、Xcode は `Contents/Resources/<dir>`。
  private func resource(_ name: String, directory: String, bundle: String) -> URL? {
    guard let root = queriesRoot else { return nil }
    let bundle = root.appendingPathComponent("\(bundle).bundle", isDirectory: true)
    for dir in [directory, "Contents/Resources/\(directory)"] {
      let url = bundle.appendingPathComponent(dir, isDirectory: true).appendingPathComponent(name)
      if FileManager.default.isReadableFile(atPath: url.path) { return url }
    }
    return nil
  }
}
