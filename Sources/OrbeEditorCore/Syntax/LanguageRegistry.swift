import Foundation
import os
@preconcurrency import SwiftTreeSitter
@preconcurrency import SwiftTreeSitterLayer

/// 文法ごとの `LanguageConfiguration`（パーサ＋queries）を、注入された queries の根から解く。
/// 根は `.app` なら `Contents/Resources`、`swift build` なら `.build/<config>` で、そこに SwiftPM の
/// 資源バンドル `<bundleName>.bundle` が並ぶ。根が nil・バンドル不在・queries が読めないときは nil＝
/// 色無しで、失敗として扱わない。結果はキャッシュする。複数の文書の構文の裏の仕事から同時に引かれるので、キャッシュは
/// lock で守る（初めて使う文法はその場で組む）。
public final class LanguageRegistry: Sendable {
  private let queriesRoot: URL?
  private let cache = OSAllocatedUnfairLock(initialState: [Grammar: LanguageConfiguration?]())

  public init(queriesRoot: URL?) {
    self.queriesRoot = queriesRoot
  }

  func configuration(for language: SyntaxLanguage) -> LanguageConfiguration? {
    configuration(for: language.grammar)
  }

  /// injections.scm が名乗る言語名から構成を引く（`LanguageLayer` の languageProvider）。
  var languageProvider: LanguageLayer.LanguageProvider {
    { [self] name in
      Grammar(injectionName: name).flatMap { configuration(for: $0) }
    }
  }

  /// 組むのは lock の外——初めての文法を組む間、他の文書（main を含む）が別の文法を引くのを待たせない。同じ文法を同時に
  /// 組んだときは先に入れた方を使う。
  func configuration(for grammar: Grammar) -> LanguageConfiguration? {
    if let cached = cache.withLock({ $0[grammar] }) { return cached }
    let configuration = load(grammar)
    return cache.withLock { cache in
      if let cached = cache[grammar] { return cached }
      cache[grammar] = configuration
      return configuration
    }
  }

  private func load(_ grammar: Grammar) -> LanguageConfiguration? {
    let language = grammar.language
    guard let highlights = query(grammar.highlightFiles, for: language) else { return nil }
    var queries: [Query.Definition: Query] = [.highlights: highlights]
    if let file = grammar.injectionFile, let injections = query([file], for: language) {
      queries[.injections] = injections
    }
    return LanguageConfiguration(language, name: grammar.rawValue, queries: queries)
  }

  /// 複数ファイルを連結して 1 つの Query に組む。どれか 1 つでも無ければ nil。
  private func query(_ files: [Grammar.QueryFile], for language: Language) -> Query? {
    var source = Data()
    for file in files {
      guard let url = url(of: file), let data = try? Data(contentsOf: url) else { return nil }
      source.append(data)
      source.append(0x0A)
    }
    return try? Query(language: language, data: source)
  }

  /// バンドル内の queries の所在。SwiftPM は `<bundle>/queries`、Xcode は `Contents/Resources/queries`。
  private func url(of file: Grammar.QueryFile) -> URL? {
    guard let root = queriesRoot else { return nil }
    let bundle = root.appendingPathComponent("\(file.grammar.bundleName).bundle", isDirectory: true)
    for dir in ["queries", "Contents/Resources/queries"] {
      let url = bundle.appendingPathComponent(dir, isDirectory: true).appendingPathComponent(
        file.name)
      if FileManager.default.isReadableFile(atPath: url.path) { return url }
    }
    return nil
  }
}
