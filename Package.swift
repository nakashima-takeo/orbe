// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Orbe",
  platforms: [.macOS(.v14)],
  dependencies: [
    // CommonMark + GFM パーサ（公式）。EditorPane の markdown を AST へ起こし SwiftUI へ再帰描画する。
    .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0"),
    // アプリ内アップデート（appcast + EdDSA 署名検証 + 終了時適用）。UI は自前（SPUUserDriver 実装）。
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
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
    .executableTarget(
      name: "Orbe",
      dependencies: [
        "GhosttyKit",
        "OrbePaths",
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      // EditorPane のファイル種別アイコン（catppuccin/vscode-icons mocha・MIT。出所は NOTICE）。
      resources: [.copy("Resources/icons")],
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
    // Orbe 自身を構成・操作する CLI（config / ws / pane / tab）。control.sock へ JSON-RPC を直接送る。
    // .app 同梱時は Contents/Resources/bin/orb へ改名され、ペイン PATH で bare `orb` に解決する。
    // GhosttyKit/AppKit に依存しない独立実行体（Foundation のみ）。
    .executableTarget(
      name: "orbe-cli",
      dependencies: ["OrbePaths"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // エージェント hook → Orbe の状態報告 CLI（.app 同梱・env で位置を指される）。
    // 制御ソケットへ JSON-RPC 1 行を送る薄い独立実行体（Foundation のみ）。
    .executableTarget(
      name: "orbe-report",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbePathsTests",
      dependencies: ["OrbePaths"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbeTests",
      dependencies: ["Orbe"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbeCliTests",
      dependencies: ["orbe-cli"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "OrbeReportTests",
      dependencies: ["orbe-report"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
