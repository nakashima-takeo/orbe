---
title: ビルド手順
description: Orbe.app の生成・起動まで。前提ツール・ghostty の pin と改造・チャネル・lint / format
updated: 2026-10-06
---

# ビルド手順

libghostty は、ghostty の fork [`nakashima-takeo/ghostty`](https://github.com/nakashima-takeo/ghostty) が固定 SHA で焼いた配布物（Release の `GhosttyKit.zip`）を、SwiftPM が取得して使う。Orbe のビルドは ghostty を焼かない。

## 前提ツール

| ツール | 要否 | 入手 |
|---|---|---|
| **フル Xcode（26 系以上）** | **必須** | App Store か Apple Developer から。Swift ツールチェーンと Icon Composer 形式のアイコンを扱う `actool` を使う。CLT だけでは不可。 |
| [mise](https://mise.jdx.dev/) | lint に必須 | `brew install mise`。[`mise.toml`](../../mise.toml) が固定する SwiftLint の版を導入・解決する台帳。導入は `mise install`。 |

Xcode を導入して初回セットアップを済ませたら、使用中の開発ツールを確認する。

```bash
xcode-select -p
xcodebuild -version
```

`xcode-select -p` が `/Library/Developer/CommandLineTools` を指している場合は、使う Xcode へ切り替える。標準の配置なら次のコマンドを使う。

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

アイコンは [`app/Orbe.icon`](../../app/Orbe.icon/) の [Icon Composer 形式](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)を使い、[`build-app.sh`](../../scripts/build-app.sh) が `actool` でコンパイルする。CLT には `actool` が無い（実測）ので、フル Xcode は回避不能。

## バージョン pin

- ghostty: [`Package.swift`](../../Package.swift) の GhosttyKit の url にあるタグ `ghosttykit-<SHA>` が pin。SHA を直書きするのはここだけ。タグはその SHA のコミットを指す。API の正はその SHA の `include/ghostty.h`（xcframework の `Headers/` にも入っている。外部契約は [spec/terminal/libghostty.md](../spec/terminal/libghostty.md)）。
- libghostty は alpha・API 非安定のため、**main 追従ではなく固定 SHA で pin**。アップグレード時はヘッダの型差分を確認。
- 配布物 `GhosttyKit.zip` の中身は `GhosttyKit.xcframework`（ReleaseFast・arm64）、`share/{ghostty,terminfo}`、`fonts/`（JetBrains Mono Nerd Font 4 本）、配布物自身の帰属表記（`NOTICE`・`licenses/`）。焼き方は fork の `orbe/build.sh` が持つ。
- pin を進める:
  1. 新しい SHA が fork に無ければ、上流の追従（fork の `orbe/README.md`）か、改造の push で fork のブランチに入れる。
  2. 所有者のトークン（手元の `gh` の認証）で tag を打つ。workflow の GITHUB_TOKEN は、workflow ファイルが既定ブランチと違うコミットに tag を作れないため。
     ```bash
     gh api repos/nakashima-takeo/ghostty/git/refs -f ref=refs/tags/ghosttykit-<40 桁 SHA> -f sha=<40 桁 SHA>
     ```
  3. fork の workflow を `main` から起動する（`gh workflow run orbe-ghosttykit.yml --repo nakashima-takeo/ghostty --ref main -f ghostty_sha=<40 桁 SHA>`）。zig の版は焼くソースの `build.zig.zon`（`minimum_zig_version`）から決まる。workflow は zip を自己検証してから、その tag に Release `ghosttykit-<SHA>` を出し、`GhosttyKit.zip` と `GhosttyKit.zip.sha256` を置く。Release を出す前に失敗したら、同じ tag のまま起動し直せばよい。
  4. `Package.swift` の url を新しい tag に、checksum を `.sha256` の中身に書き換える。
- 依存の顔ぶれが変わったときは [licensing](../spec/platform/licensing.md) に従う。
- 公開した Release は差し替えない（checksum を全員が固定しているため。fork は Immutable releases にしてある）。焼き直しが要るときは ghostty の SHA を変える。
- tree-sitter 本体は `exact: "0.26.11"`（C API を `OrbeEditorCore` から直接呼ぶ）。0.26.12・0.26.13 はエラー回復が退行していて、Orbe のソースを連結した 1.2MB の Swift が文書全体で ERROR 1 つに崩れ、色がほぼ消える。退行は 2 つある——0.26.12 の 3ee7c639（master の 15ea3328）は UTF-16 の入力で、0.26.13 の f837fc98（master の 869638f6、上流 Issue #5910）は UTF-8 でも崩す。どちらも 0.27.0 にある。0.26.12〜13 で入った query の修正は、同梱の queries の結果を変えない（直ったのは量化子のすぐ隣に置いた anchor と `(MISSING)` の扱いで、どちらも使っていない）。
- tree-sitter を上げるときに確かめること: 実在の大きなファイル（Orbe の `Sources` を連結した Swift など）を UTF-16 で解析して（Orbe の入力。tree-sitter の CLI は UTF-8 で解くので、UTF-16 だけの崩れを見逃す）全体 ERROR に崩れない／同梱の queries（highlights は連結、injections は単独）がすべて組める／誤りの無い見本（16 文法）の構文木と capture の列が前の版と一致する。
- tree-sitter 0.27 以降は上流の `Package.swift` が無い。上げるときは `lib` の C ソースを取り込む自前の target に移る（sources は `lib/src/lib.c` の 1 本、公開ヘッダは `lib/include`——上流の CMake と同じ組み方。0.27.0 の `lib/src` には wasm 用の C（`src/wasm-stdlib`）があり、`lib/src` を丸ごと sources にするとそれまで拾ってネイティブでは組めない）。
- 文法のうち javascript 0.23.1 / css 0.23.2 / python 0.23.6 / yaml 0.7.0 は `exact`。これより新しいタグ（javascript / css / python の v0.25.0、yaml の v0.7.1 以降）の `Package.swift` は `sources` を `FileManager.default.fileExists(atPath: "src/scanner.c")` で条件分岐しており、依存として評価されると cwd 相対の判定が false になって scanner.c がリンクされない（ファイル自体は存在する）。上げるときは当該タグの `Package.swift` の `sources` が `fileExists` で分岐していないか確認する——分岐していれば scanner.c を持つ文法は必ずリンクに失敗する。`from:` の文法も上流が同じ manifest へ移れば同じ失敗をする。
- swift 0.7.3-with-generated-files も `exact`。生成済みの `src/parser.c` を持つのは `-with-generated-files` の付いたタグだけで（素のタグ `0.7.3` の `src/` には無い）、SemVer ではこれはプレリリースなので素のタグより古い版になる。`from:` にすると parser.c の無いタグに解決されてビルドが落ちる。上げるときも `-with-generated-files` の付いたタグを `exact` で指す。

## ビルド手順（Xcode 導入後）

```bash
git clone https://github.com/nakashima-takeo/orbe.git
cd orbe
./scripts/build-app.sh
open build/Orbe.app
```

`git worktree add` で切った作業場でも、何も準備せずに同じコマンドで動く。`GhosttyKit.zip`（約 40MB）は初回の `swift build` で取得され、ユーザー単位のキャッシュ（`~/Library/Caches/org.swift.swiftpm`）に残るので、2 つ目以降の作業場では再ダウンロードしない。展開先は作業場ごとの `.build`。

`build/Orbe.app` と `/Applications/Orbe Dev.app` は同じ bundle id なので、state も control.sock も共有する。`open` は既存インスタンスを前面化するだけでソケットの持ち主は入れ替わらないため、常用の Orbe Dev を起動したまま新ビルドを起こしても古い方が応答し続ける（症状は「新ビルドにしたのに直っていない」という遠い形で出る）。入れ替えるには先に常用を quit するか、本物に触らず確かめるなら `ORBE_STATE_DIR` で隔離する（`scripts/sandbox-run.sh start`。手順は `.claude/skills/sandbox-run`）。

`build-app.sh` は `swift build -c release` の後、SwiftPM が `GhosttyKit.zip` を展開した先（`.build/artifacts/<作業場のディレクトリ名の小文字>/GhosttyKit/`）から share とフォントを Orbe.app に同梱する。見つからなければ止まる。

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
  bundle id 由来なので自動で分かれる（[persistence](../spec/platform/persistence.md)）。成果物パスは両者とも `build/Orbe.app`。
- release をオプトインにしてあるのは、素の `swift build`（`scripts/orbe-mcp.sh` 等）がフラグ差分で
  焼き直しても dev のままになるようにするため。逆にすると、そこで本番 identity へ静かに落ちる。

> 静的ライブラリのため Package.swift で Metal/CoreText/AppKit 等のシステムフレームワークを明示リンクしている。

### リソース解決（GHOSTTY_RESOURCES_DIR は不要）

ghostty は shell-integration / themes / terminfo を**実行体からの相対**で自動検出する（`Contents/Resources/terminfo/78/xterm-ghostty` をセンチネルに climb）。`build-app.sh` がこれらを `Orbe.app/Contents/Resources/{ghostty,terminfo}` に同梱するため、`.app` は **環境変数なしで自己完結**する（ghostty 公式アプリと同じ方式）。

エディターの色付け規則（tree-sitter の queries）は SwiftPM が文法ごとに `TreeSitter<Pkg>_TreeSitter<Target>.bundle` へ写す。`build-app.sh` がそれを `Contents/Resources/` 直下へ並べ（16 個揃わなければ落ちる）、`swift build` ではビルド成果物の隣（`.build/<config>/`）にあるので、どちらでも `LanguageRegistry` が実行体の隣から解く。テストは同梱物を持たない実行体なので `.build/debug` を明示注入する。

`swift build` の **debug バイナリを単体起動する dev 時のみ**、リソースが実行体の隣に無いため env を渡す:
```bash
GHOSTTY_RESOURCES_DIR="$PWD/.build/artifacts/$(basename "$PWD" | tr '[:upper:]' '[:lower:]')/GhosttyKit/share/ghostty" .build/debug/Orbe
```

## ghostty を改造して試す

前提: Metal Toolchain（`xcodebuild -downloadComponent MetalToolchain`）と、焼くソースの `build.zig.zon` の `minimum_zig_version` に合う Zig（ghostty の build は major.minor の一致と、patch が最小値以上であることを要求する）。

1. fork を `git clone --no-tags https://github.com/nakashima-takeo/ghostty.git` で取り、pin の SHA からブランチを切って改造する。タグを取らないのは、ghostty の build が HEAD に付いたタグをリリースの版とみなし、焼いたコミットに付く fork の Release タグで止まるため。
2. fork の `main` の `orbe/build.sh <改造したソース> <zip>` で zip を作る。ソースが `orbe/` を含まないときは、`main` の checkout（または `git worktree`）から build.sh を実行する。
3. Orbe の `Package.swift` の GhosttyKit を一時的に `.binaryTarget(name: "GhosttyKit", path: "<zip への相対パス>")` に差し替え、`swift build` か `build-app.sh` を実行する。zip を作り直せば次のビルドで再展開される。差し替えはコミットしない。

改造を pin にするときは、ブランチを fork に push し、その SHA で「pin を進める」の 2 から従う。

## lint・format

- lint: `mise exec -- swiftlint lint --strict --quiet`（SwiftLint。バージョンは mise.toml で pin。導入は `mise install`）
- format チェック: `swift format lint --strict --recursive Sources Tests Package.swift`／整形: `swift format --in-place --recursive Sources Tests Package.swift`（toolchain 内蔵）
- コミット時の自動チェック: `brew install lefthook && lefthook install`（clone 後 1 回）
- CI（GitHub Actions）が push / PR で lint・format・build・test を実行する
