# ビルド手順

Orbe は libghostty を**自前ビルド**して使う（クリーン・MIT・自己完結）。

## 前提ツール

| ツール | 要否 | 入手 |
|---|---|---|
| **フル Xcode** | **必須** | CLT だけでは不可（後述）。App Store か Apple Developer から。 |
| Zig 0.15.2 | 必須 | `brew install zig@0.15`。ghostty が `minimum_zig_version = 0.15.2` を要求し、brew の素の `zig`(0.16) では不可。**`zig@0.15` は keg-only なので `zig` は PATH に入らない**が、`build-app.sh` が `brew --prefix zig@0.15` から自動解決する（別経路で入れた場合は `ZIG=/path/to/zig` で上書き）。 |
| ディスク空き | ~20GB+ | Xcode 展開用。 |

### なぜフル Xcode が必須か（CLT では不可）

実測で確定：

1. CLT には **Metal コンパイラが無い**（`xcrun -sdk macosx metal` → `unable to find utility "metal"`）。ghostty の macOS レンダラは Metal シェーダのコンパイルが要る。
2. それ以前に、CLT だけだと `zig build` が**構成段階で失敗**する（`error: DarwinSdkNotFound`）。ghostty のビルドグラフ生成に Darwin SDK が要る。

→ Metal 描画のネイティブアプリを自前ビルドする以上、フル Xcode は回避不能。

## バージョン pin

- ghostty: `vendor/ghostty` submodule を `3ba5e9c24390412fb1dbb08c51008f1efdcff97b` に pin。
  API の正はこのコミットの `vendor/ghostty/include/ghostty.h`（外部契約は [spec/libghostty.md](spec/libghostty.md)）。
- libghostty は alpha・API 非安定のため、**main 追従ではなく固定 SHA で pin**。アップグレード時はヘッダの型差分を確認。

## ビルド手順（Xcode 導入後）

```bash
# 1. submodule 取得
git submodule update --init --recursive

# 2. Orbe.app を生成して起動
./scripts/build-app.sh
open build/Orbe.app
```

`build-app.sh` がエンジン(libghostty)を ReleaseFast で焼き（`zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast`）、xcframework と share リソースを生成してから Orbe.app をバンドルする。初回・submodule 更新時は数分かかるが、以降は Zig のキャッシュで実質一瞬。

### ビルドチャネル（ORBE_CHANNEL）

`ORBE_CHANNEL`（既定 `dev`）がチャネルの唯一の入力。`build-app.sh` がここから identity・Swift 定義・
アイコンをすべて導出する。`release-app.sh`（公開リリース）だけが `export ORBE_CHANNEL=release` して呼ぶ。

| | dev（既定） | release |
|---|---|---|
| CFBundleIdentifier | `dev.orbe.app.dev` | `dev.orbe.app` |
| CFBundleName / DisplayName | Orbe Dev | Orbe |
| Swift 定義 | なし | `-Xswiftc -DORBE_RELEASE` |
| アイコン背景 | アンバー | 白/紫 |
| `install.sh` の据え先 | `/Applications/Orbe Dev.app` | （公開 DMG から手で置く） |

- dev と release は**別 identity のアプリとして共存する**。state dir・control.sock・UserDefaults は
  bundle id 由来なので自動で分かれる（[persistence](spec/persistence.md)）。成果物パスは両者とも `build/Orbe.app`。
- release をオプトインにしてあるのは、素の `swift build`（`scripts/orbe-mcp.sh` 等）がフラグ差分で
  焼き直しても dev のままになるようにするため。逆にすると、そこで本番 identity へ静かに落ちる。
- `-DORBE_RELEASE` は設定パレットの「開発中の機能を有効化」トグルの**未設定時 default**も決める（dev=on / release=off）。
  `#if DEBUG` は使えない（開発用も公開用も一律 `swift build -c release` で焼くため両ビルドとも false）。

> **worktree での注意**: `git worktree add` で切った作業場では submodule は未取得のまま。`git submodule update` は不要（main のオブジェクトを共有せずフル clone を試み重い）。`build-app.sh` が `vendor/ghostty/build.zig` 不在を検知し、main worktree の `vendor/ghostty` へ symlink を張って自動で用意する。**worktree では `vendor/ghostty` を手動で触らない**（submodule 取得も xcframework コピーも不要）。

> 静的ライブラリのため Package.swift で Metal/CoreText/AppKit 等のシステムフレームワークを明示リンクしている。

### リソース解決（GHOSTTY_RESOURCES_DIR は不要）

ghostty は shell-integration / themes / terminfo を**実行体からの相対**で自動検出する（`Contents/Resources/terminfo/78/xterm-ghostty` をセンチネルに climb）。`build-app.sh` がこれらを `Orbe.app/Contents/Resources/{ghostty,terminfo}` に同梱するため、`.app` は **環境変数なしで自己完結**する（ghostty 公式アプリと同じ方式）。

`swift build` の **debug バイナリを単体起動する dev 時のみ**、リソースが実行体の隣に無いため env を渡す:
```bash
GHOSTTY_RESOURCES_DIR="$PWD/vendor/ghostty/zig-out/share/ghostty" .build/debug/Orbe
```

## lint・format

- lint: `mise exec -- swiftlint lint --strict --quiet`（SwiftLint。バージョンは mise.toml で pin。導入は `mise install`）
- format チェック: `swift format lint --strict --recursive Sources Tests Package.swift`／整形: `swift format --in-place --recursive Sources Tests Package.swift`（toolchain 内蔵）
- コミット時の自動チェック: `brew install lefthook && lefthook install`（clone 後 1 回）
- CI（GitHub Actions）が push / PR で lint・format・build・test を実行する
