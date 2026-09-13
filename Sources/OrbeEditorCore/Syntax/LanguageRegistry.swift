import Foundation
import SwiftTreeSitter
import SwiftTreeSitterLayer

/// 文法ごとの `LanguageConfiguration`（パーサ＋queries）を、注入された queries の根から解く。
/// 根は `.app` なら `Contents/Resources`、`swift build` なら `.build/<config>` で、そこに SwiftPM の
/// 資源バンドル `<bundleName>.bundle` が並ぶ。根が nil・バンドル不在・queries が読めないときは nil＝
/// 色無しで、失敗として扱わない。結果はキャッシュする。
public final class LanguageRegistry {
  private let queriesRoot: URL?
  private var cache: [Grammar: LanguageConfiguration?] = [:]

  public init(queriesRoot: URL?) {
    self.queriesRoot = queriesRoot
  }

  public func configuration(for language: SyntaxLanguage) -> LanguageConfiguration? {
    configuration(for: language.grammar)
  }

  /// injections.scm が名乗る言語名から構成を引く（`LanguageLayer` の languageProvider）。
  var languageProvider: LanguageLayer.LanguageProvider {
    { [weak self] name in
      guard let self, let grammar = Grammar(injectionName: name) else { return nil }
      return self.configuration(for: grammar)
    }
  }

  func configuration(for grammar: Grammar) -> LanguageConfiguration? {
    if let cached = cache[grammar] { return cached }
    let configuration = load(grammar)
    cache[grammar] = configuration
    return configuration
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
