#!/usr/bin/env bash
# Orbe.app を生成する（自己署名・自己完結）。エンジン(libghostty)のビルドも内包する。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Orbe.app"
SHARE="$ROOT/vendor/ghostty/zig-out/share"

# --- worktree ガード: submodule 未取得なら main worktree の vendor/ghostty へ symlink ---
# git worktree add は submodule を checkout せず、worktree での submodule update は main の
# オブジェクトを共有せずフル clone を試みて重い。エンジンは pin SHA 不変ゆえ、main worktree の
# vendor/ghostty（zig-out 含む）を symlink で共有すればビルドが通る（zig は cache hit で実質 read-only）。
if [ ! -f "$ROOT/vendor/ghostty/build.zig" ]; then
  MAIN_WT="$(git -C "$ROOT" worktree list --porcelain | sed -n 's/^worktree //p' | head -1)"
  if [ -z "$MAIN_WT" ] || [ ! -f "$MAIN_WT/vendor/ghostty/build.zig" ]; then
    echo "エラー: main worktree の vendor/ghostty を解決できない ($MAIN_WT)。main で submodule を取得済みか確認せよ" >&2
    exit 1
  fi
  echo "==> worktree 検出: vendor/ghostty を main worktree へ symlink ($MAIN_WT)"
  rm -rf "$ROOT/vendor/ghostty"
  ln -s "$MAIN_WT/vendor/ghostty" "$ROOT/vendor/ghostty"
  # ビルド後（EXIT/INT/TERM）に symlink を submodule 未 checkout（空ディレクトリ）へ戻す。
  # symlink を残すと git status がエラーになり lefthook・確定コミット・worktree remove を壊す。
  # .app には share/font をコピー済みで、vendor はビルド完了後は不要（次回ビルドで再 symlink）。
  trap 'rm -rf "$ROOT/vendor/ghostty"; mkdir "$ROOT/vendor/ghostty"' EXIT INT TERM
fi

# zig@0.15 は keg-only で brew が PATH に通さない。素の `zig` は 0.16 が入りうるが
# ghostty は minimum_zig_version = 0.15.2 を要求するため通らない。brew prefix から
# 解決し、別経路で入れている場合は ZIG で上書きできるようにする。
ZIG="${ZIG:-}"
if [ -z "$ZIG" ]; then
  if zig_prefix="$(brew --prefix zig@0.15 2>/dev/null)" && [ -x "$zig_prefix/bin/zig" ]; then
    ZIG="$zig_prefix/bin/zig"
  else
    ZIG="zig"
  fi
fi
if ! command -v "$ZIG" >/dev/null 2>&1; then
  echo "エラー: zig が見つからない ($ZIG)。'brew install zig@0.15' 後、必要なら ZIG=/path/to/zig を指定せよ" >&2
  exit 1
fi

echo "==> エンジン(libghostty)を ReleaseFast でビルド"
echo "    初回・submodule 更新時は数分かかる（以降は Zig キャッシュで一瞬）"
(cd "$ROOT/vendor/ghostty" && "$ZIG" build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast)

echo "==> swift build -c release"
# 開発ビルド（build-app.sh 直叩き等）は -DORBE_DEV を焼き、「開発中の機能を
# 有効化」トグルの未設定 default を on にする。公開リリース（release-app.sh）だけ ORBE_CHANNEL=release を
# 立ててフラグを抑止し default off にする。この env はこの分岐だけが読む。
DEV_DEFINE=()
[ "${ORBE_CHANNEL:-dev}" != "release" ] && DEV_DEFINE=(-Xswiftc -DORBE_DEV)
swift build -c release ${DEV_DEFINE[@]+"${DEV_DEFINE[@]}"} --package-path "$ROOT"

echo "==> バンドル生成: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Orbe" "$APP/Contents/MacOS/Orbe"
cp -R "$ROOT/.build/release/Orbe_Orbe.bundle" "$APP/Contents/Resources/Orbe_Orbe.bundle"  # SwiftPM リソース（EditorPane のファイル種別アイコン）
mkdir -p "$APP/Contents/Resources/bin"
cp "$ROOT/.build/release/orbe-report" "$APP/Contents/Resources/bin/orbe-report"  # エージェント hook が env パスで指す状態報告 CLI（署名対象）
cp "$ROOT/.build/release/orbe-cli" "$APP/Contents/Resources/bin/orb"  # Orbe 構成 CLI（bare `orb` へ改名・ペイン PATH で解決・署名対象）
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
# git 短縮 SHA を build-id として刻む（検証インスタンスが鮮度を名乗るため。dirty なら +）。
BUILD_ID="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$ROOT" diff --quiet -- . ':(exclude)vendor/ghostty' 2>/dev/null || BUILD_ID="$BUILD_ID+"
/usr/libexec/PlistBuddy -c "Add :OrbeBuildID string $BUILD_ID" "$APP/Contents/Info.plist"
cp "$ROOT/app/orbe-defaults.conf" "$APP/Contents/Resources/orbe-defaults.conf"
cp "$ROOT/app/orbe-completion.zsh" "$APP/Contents/Resources/orbe-completion.zsh"  # zsh ドロップダウン補完 widget（env ORBE_COMPLETION_ZSH が指す source 先・署名対象）
cp "$ROOT/app/completion-engine.js" "$APP/Contents/Resources/completion-engine.js"  # JSC 補完エンジン（inshellisense runtime + curated withfig spec の prebuilt バンドル・署名対象）
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"    # Orbe 自身のライセンス (GPL-3.0-or-later)
cp "$ROOT/NOTICE" "$APP/Contents/Resources/NOTICE"      # 第三者の帰属表示
cp -R "$ROOT/licenses" "$APP/Contents/Resources/licenses"  # 第三者ライセンス全文（OFL-1.1 等は全文同梱が要求される）
# アプリアイコン: Icon Composer の app/Orbe.icon を actool でコンパイルし、
# Assets.car（macOS 26+ の light/dark 外観切替）と Orbe.icns（macOS 14–25 フォールバック）を
# 同時生成して Resources へ出力する。Info.plist は CFBundleIconName=Orbe で参照する。
xcrun actool "$ROOT/app/Orbe.icon" \
  --compile "$APP/Contents/Resources" \
  --app-icon Orbe \
  --output-partial-info-plist "$(mktemp -d)/orbe-icon-partial.plist" \
  --platform macosx --minimum-deployment-target 14.0 \
  --errors --warnings --output-format human-readable-text >/dev/null
cp -R "$SHARE/ghostty" "$APP/Contents/Resources/ghostty"
# themes は ghostty stock を同梱せず Orbe 自前の 2枚のみ（テーマは Auto/Dark/Light の外観スイッチで、
# 端末色はこのペアに固定。ghostty の named theme 解決はこのディレクトリを見るため 2 枚は必須）。
rm -rf "$APP/Contents/Resources/ghostty/themes"
mkdir -p "$APP/Contents/Resources/ghostty/themes"
cp "$ROOT/app/themes/OrbeDark"  "$APP/Contents/Resources/ghostty/themes/OrbeDark"   # Orbe 自前 named theme（dark）
cp "$ROOT/app/themes/OrbeLight" "$APP/Contents/Resources/ghostty/themes/OrbeLight"  # Orbe 自前 named theme（light）
cp -R "$SHARE/terminfo" "$APP/Contents/Resources/terminfo"
cp -R "$ROOT/app/agent-plugin" "$APP/Contents/Resources/agent-plugin"  # エージェント状態追跡プラグイン（各 CLI へ自動導入する配布物）
# 本文プライマリの JetBrains Mono を4スタイル同梱（bold/italic を設計字形で決定論解決）。Regular はタブの状態アイコンにも使う。
cp "$ROOT/vendor/ghostty/src/font/res/JetBrainsMonoNerdFont-Regular.ttf" "$APP/Contents/Resources/JetBrainsMonoNerdFont-Regular.ttf"
cp "$ROOT/vendor/ghostty/src/font/res/JetBrainsMonoNerdFont-Bold.ttf" "$APP/Contents/Resources/JetBrainsMonoNerdFont-Bold.ttf"
cp "$ROOT/vendor/ghostty/src/font/res/JetBrainsMonoNerdFont-Italic.ttf" "$APP/Contents/Resources/JetBrainsMonoNerdFont-Italic.ttf"
cp "$ROOT/vendor/ghostty/src/font/res/JetBrainsMonoNerdFont-BoldItalic.ttf" "$APP/Contents/Resources/JetBrainsMonoNerdFont-BoldItalic.ttf"
cp "$ROOT/vendor/ghostty/src/font/res/JuliaMono-Regular.ttf" "$APP/Contents/Resources/JuliaMono-Regular.ttf"  # 記号の広カバレッジ fallback（discovery より前で決定論化・起動時 .process 登録）
cp "$ROOT/app/NotoColorEmoji-sbix.ttf" "$APP/Contents/Resources/NotoColorEmoji-sbix.ttf"  # タブタイトルのカラー絵文字（CBDT→sbix 変換済み・scripts/convert-noto-emoji-sbix.py で生成・TitleGlyphs がファイル直ロード）

echo "==> 自己署名 (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> 完了: open '$APP'"
