import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterDockerfile
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// ファイルとして開ける言語。拡張子／ファイル名から決まり、文法（`Grammar`）を 1 つ指す。
public enum SyntaxLanguage: String, CaseIterable, Sendable {
  case swift, markdown, json, typescript, javascript, tsx, css, html, python, go, rust, yaml, toml
  case bash, dockerfile

  /// 拡張子（小文字比較）とファイル名から言語を決める。決まらなければ nil＝色無し。
  public static func detect(url: URL) -> SyntaxLanguage? {
    let name = url.lastPathComponent
    if name == "Dockerfile" || name.hasPrefix("Dockerfile.") { return .dockerfile }
    switch url.pathExtension.lowercased() {
    case "swift": return .swift
    case "md", "markdown": return .markdown
    case "json": return .json
    case "ts", "mts", "cts": return .typescript
    case "js", "mjs", "cjs", "jsx": return .javascript
    case "tsx": return .tsx
    case "css": return .css
    case "html", "htm": return .html
    case "py": return .python
    case "go": return .go
    case "rs": return .rust
    case "yaml", "yml": return .yaml
    case "toml": return .toml
    case "sh", "bash", "zsh": return .bash
    case "dockerfile": return .dockerfile
    default: return nil
    }
  }

  var grammar: Grammar {
    switch self {
    case .swift: return .swift
    case .markdown: return .markdown
    case .json: return .json
    case .typescript: return .typescript
    case .javascript: return .javascript
    case .tsx: return .tsx
    case .css: return .css
    case .html: return .html
    case .python: return .python
    case .go: return .go
    case .rust: return .rust
    case .yaml: return .yaml
    case .toml: return .toml
    case .bash: return .bash
    case .dockerfile: return .dockerfile
    }
  }
}

/// tree-sitter の文法 1 つ。ファイルの言語 15 に、Markdown の inline（injection でしか現れない）を足した 16。
/// queries の組み方（上流の `tree-sitter.json` が highlights を複数ファイルで重ねる言語がある）と
/// バンドル名（規則外の 2 つ）をここが持つ。
enum Grammar: String, CaseIterable, Sendable {
  case swift, markdown, markdownInline, json, typescript, javascript, tsx, css, html, python, go
  case rust, yaml, toml, bash, dockerfile

  /// injections.scm が名乗る言語名（と fenced code の慣用名）から文法を引く。
  init?(injectionName: String) {
    switch injectionName.lowercased() {
    case "swift": self = .swift
    case "markdown", "md": self = .markdown
    case "markdown_inline": self = .markdownInline
    case "json": self = .json
    case "typescript", "ts": self = .typescript
    case "javascript", "js": self = .javascript
    case "tsx": self = .tsx
    case "css": self = .css
    case "html": self = .html
    case "python", "py": self = .python
    case "go", "golang": self = .go
    case "rust", "rs": self = .rust
    case "yaml", "yml": self = .yaml
    case "toml": self = .toml
    case "bash", "sh", "shell", "zsh": self = .bash
    case "dockerfile", "docker": self = .dockerfile
    default: return nil
    }
  }

  var language: Language {
    switch self {
    case .swift: return Language(tree_sitter_swift())
    case .markdown: return Language(tree_sitter_markdown())
    case .markdownInline: return Language(tree_sitter_markdown_inline())
    case .json: return Language(tree_sitter_json())
    case .typescript: return Language(tree_sitter_typescript())
    case .javascript: return Language(tree_sitter_javascript())
    case .tsx: return Language(tree_sitter_tsx())
    case .css: return Language(tree_sitter_css())
    case .html: return Language(tree_sitter_html())
    case .python: return Language(tree_sitter_python())
    case .go: return Language(tree_sitter_go())
    case .rust: return Language(tree_sitter_rust())
    case .yaml: return Language(tree_sitter_yaml())
    case .toml: return Language(tree_sitter_toml())
    case .bash: return Language(tree_sitter_bash())
    case .dockerfile: return Language(tree_sitter_dockerfile())
    }
  }

  /// SwiftPM が queries を写す資源バンドルの名前（`<パッケージ名>_<ターゲット名>`）。
  var bundleName: String {
    switch self {
    case .swift: return "TreeSitterSwift_TreeSitterSwift"
    case .markdown: return "TreeSitterMarkdown_TreeSitterMarkdown"
    case .markdownInline: return "TreeSitterMarkdown_TreeSitterMarkdownInline"
    case .json: return "TreeSitterJSON_TreeSitterJSON"
    case .typescript: return "TreeSitterTypeScript_TreeSitterTypeScript"
    case .javascript: return "TreeSitterJavaScript_TreeSitterJavaScript"
    case .tsx: return "TreeSitterTypeScript_TreeSitterTSX"
    case .css: return "TreeSitterCSS_TreeSitterCSS"
    case .html: return "TreeSitterHTML_TreeSitterHTML"
    case .python: return "TreeSitterPython_TreeSitterPython"
    case .go: return "TreeSitterGo_TreeSitterGo"
    case .rust: return "TreeSitterRust_TreeSitterRust"
    case .yaml: return "TreeSitterYAML_TreeSitterYAML"
    case .toml: return "TreeSitterTOML_TreeSitterTOML"
    case .bash: return "TreeSitterBash_TreeSitterBash"
    case .dockerfile: return "TreeSitterDockerfile_TreeSitterDockerfile"
    }
  }

  /// queries ファイル 1 つの所在（どの文法のバンドルの、どのファイルか）。
  struct QueryFile: Hashable {
    let grammar: Grammar
    let name: String
  }

  /// highlights を組むファイルの列。TypeScript / TSX は上流の `tree-sitter.json` どおり JavaScript の
  /// highlights を下に敷く（単体の highlights.scm は TS 固有の差分しか持たない）。後のファイルが先に
  /// 塗られ、前のファイルほど優先される（tree-sitter の highlight 規則）ので、上流の並びをそのまま持つ。
  var highlightFiles: [QueryFile] {
    switch self {
    case .typescript:
      return [
        QueryFile(grammar: .typescript, name: "highlights.scm"),
        QueryFile(grammar: .javascript, name: "highlights.scm"),
      ]
    case .tsx:
      return [
        QueryFile(grammar: .tsx, name: "highlights.scm"),
        QueryFile(grammar: .javascript, name: "highlights-jsx.scm"),
        QueryFile(grammar: .javascript, name: "highlights.scm"),
      ]
    default:
      return [QueryFile(grammar: self, name: "highlights.scm")]
    }
  }

  /// injections を持つ文法はその所在。TypeScript / TSX は JavaScript のものを借りる（上流どおり）。
  var injectionFile: QueryFile? {
    switch self {
    case .typescript, .tsx, .javascript:
      return QueryFile(grammar: .javascript, name: "injections.scm")
    case .markdown, .markdownInline, .html, .rust, .swift:
      return QueryFile(grammar: self, name: "injections.scm")
    case .json, .css, .python, .go, .yaml, .toml, .bash, .dockerfile: return nil
    }
  }
}
