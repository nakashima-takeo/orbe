// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Orbe",
  platforms: [.macOS(.v14)],
  dependencies: [
    // CommonMark + GFM パーサ（公式）。リリースノートの markdown を AST へ起こし SwiftUI へ描画する。
    .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0"),
    // アプリ内アップデート（appcast + EdDSA 署名検証 + 終了時適用）。UI は自前（SPUUserDriver 実装）。
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    // コードエディターのテキストエンジン（TextKit 2 の自前ビュー・ガター・rendering attribute）。GPLv3。
    .package(url: "https://github.com/krzyzanowskim/STTextView", from: "2.4.1"),
    // tree-sitter の Swift 束縛（ランタイム同梱・LanguageLayer による injections 込みの色付け）。
    // `from:` は迷子タグ 0.25.0（0.10.0 より古い）を掴むので exact で固定する（docs/guides/build.md）。
    .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.10.0"),
    // 文法 14 パッケージ（16 パーサ）。exact の 4 つは v0.25 世代 manifest が scanner.c を落として
    // リンクに失敗するため導入前タグへ固定（docs/guides/build.md）。
    .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.8"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", from: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-html", from: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-go", from: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-rust", from: "0.24.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.25.1"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.5.3"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", from: "0.7.0"),
    .package(url: "https://github.com/camdencheek/tree-sitter-dockerfile", from: "0.2.0"),
    .package(
      url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
  ],
  targets: [
    .binaryTarget(
      name: "GhosttyKit",
      path: "vendor/ghostty/macos/GhosttyKit.xcframework"
    ),
    // state dir / control.sock の解決を 3 実行体（本体・cli・mcp）で共有する薄い土台。
    // Foundation のみ・独立ライブラリ（重い本体モジュールへ結合させないため）。
    .target(
      name: "OrbePaths",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // エージェントセッションの寿命ログ（agent-sessions.jsonl）の型・読み書き・派生を本体と `orb` CLI で
    // 共有する薄い土台。Foundation のみ・独立ライブラリ（OrbePaths と同じ理由）。
    .target(
      name: "OrbeSessionLog",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // 通知音の純 DSP 層（合成プリミティブ・部品語彙・カタログ・レンダラ・取り込み・数値解析）。Foundation のみで、
    // 音を出す手段を持たない（再生は Orbe 側の SoundPlayer）。Orbe 本体と dev CLI（orbe-sound）が共有する。
    // debug でも最適化して焼く: 純 DSP のループは -Onone だと 40 倍遅く、テストが分オーダーになる。
    // 代償として、このターゲットでは `assert` / `assertionFailure` が消える（stdlib が -Onone 限定で
    // 実装している）。失敗を呼び出し側へ伝えるなら throw か戻り値で表す。
    .target(
      name: "OrbeSound",
      swiftSettings: [
        .swiftLanguageMode(.v5),
        .unsafeFlags(["-O"], .when(configuration: .debug)),
      ]
    ),
    // コードエディターの中核（文書・行索引・言語・tree-sitter の色付け・テキスト面の契約）。
    // テキストエンジン（STTextView）も Theme / L10n も知らない——境界は target 依存でコンパイラが保証する。
    .target(
      name: "OrbeEditorCore",
      dependencies: [
        .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
        .product(name: "SwiftTreeSitterLayer", package: "swift-tree-sitter"),
        .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
        .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
        .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
        .product(name: "TreeSitterGo", package: "tree-sitter-go"),
        .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
        .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
        .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
        .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
        .product(name: "TreeSitterDockerfile", package: "tree-sitter-dockerfile"),
        .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
        .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
        .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
        .product(name: "TreeSitterPython", package: "tree-sitter-python"),
        .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // テキスト面（`TextSurface`）の STTextView 実装。公開は面を作る 1 関数だけで、エンジンの型は外に出さない。
    // エンジンの移行はこの target の差し替え。
    .target(
      name: "OrbeEditorText",
      dependencies: [
        "OrbeEditorCore",
        .product(name: "STTextView", package: "STTextView"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "Orbe",
      dependencies: [
        "GhosttyKit",
        "OrbePaths",
        "OrbeSessionLog",
        "OrbeSound",
        "OrbeEditorCore",
        "OrbeEditorText",
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      // v1 土台: libghostty の C コールバックはスレッド保証が API 上不明確で、
      // Swift 6 strict concurrency では安全に表現できない（assumeIsolated は off-main でクラッシュ）。
      // main スレッド規律 + 明示ディスパッチで扱うため言語モードは 5。本格対応は後続ユニットの課題。
      swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("CoreText"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("QuartzCore"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("Carbon"),
        .linkedFramework("JavaScriptCore"),
        .linkedLibrary("stdc++"),
      ]
    ),
    // 外部 → Orbe 制御チャネルの MCP ブリッジ（control.sock へ転送する薄い層）。
    // GhosttyKit/AppKit に依存しない独立実行体（Foundation のみ）。
    .executableTarget(
      name: "orbe-mcp",
      dependencies: ["OrbePaths"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // Orbe 自身を構成・操作する CLI（config / ws / tab / agent / session / wait）。control.sock へ JSON-RPC を
    // 直接送る。.app 同梱時は Contents/Resources/bin/orb へ改名され、タブの PATH で bare `orb` に解決する。
    // GhosttyKit/AppKit に依存しない独立実行体（Foundation のみ）。
    .executableTarget(
      name: "orbe-cli",
      dependencies: ["OrbePaths", "OrbeSessionLog"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // エージェント hook → Orbe の状態報告 CLI（.app 同梱・env で位置を指される）。
    // 制御ソケットへ JSON-RPC 1 行を送る薄い独立実行体（Foundation のみ）。
    .executableTarget(
      name: "orbe-report",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // 通知音の制作ループ用 dev CLI（list / render / play / analyze / board）。app には同梱しない。
    // GhosttyKit/AppKit/control.sock に依存しない独立実行体（Foundation + OrbeSound のみ）。
    .executableTarget(
      name: "orbe-sound",
      dependencies: ["OrbeSound"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbeSoundTests",
      dependencies: ["OrbeSound"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbeSoundCliTests",
      dependencies: ["orbe-sound"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbePathsTests",
      dependencies: ["OrbePaths"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbeSessionLogTests",
      dependencies: ["OrbeSessionLog"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbeEditorCoreTests",
      dependencies: ["OrbeEditorCore"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbeTests",
      dependencies: ["Orbe", "OrbeEditorCore", "OrbeEditorText"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbeReportTests",
      dependencies: ["orbe-report"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
