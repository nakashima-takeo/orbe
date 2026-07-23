#!/usr/bin/env bash
# Orbe.app を Developer ID で署名・公証し、配布用 zip を作る。
# build-app.sh が自己完結バンドルを作り、こちらが配布用の署名・公証・パッケージングを担う
# （ローカル常用の ad-hoc 署名ビルドとは別）。
#
# 事前準備（一度だけ）:
#   1. Xcode で「Developer ID Application」証明書を作成し Keychain に入れる
#   2. xcrun notarytool store-credentials orbe-notary \
#        --apple-id <Apple ID> --team-id <Team ID> --password <app用パスワード>
#
# 使い方: scripts/release-app.sh
#   環境変数で上書き可: ORBE_SIGN_ID / ORBE_NOTARY_PROFILE
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_APP="$ROOT/build/Orbe.app"     # build-app.sh の出力。開発ビルドがいつでも上書きする。
RELEASE_DIR="$ROOT/build/release"
APP="$RELEASE_DIR/Orbe.app"          # 署名・公証・staple・zip は隔離したこちらに対して行う。
                                       # 公証は初回だと数時間かかることがあり、その間に BUILD_APP が
                                       # 差し替わると cdhash が変わって staple が永久に通らなくなるため。
ENTITLEMENTS="$ROOT/app/orbe.entitlements"

SIGN_ID="${ORBE_SIGN_ID:-Developer ID Application}"      # Keychain の配布用証明書
NOTARY_PROFILE="${ORBE_NOTARY_PROFILE:-orbe-notary}"   # notarytool store-credentials で作った名前

# 前提チェック（証明書が無ければ何もしないうちに止める）。
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  echo "エラー: '$SIGN_ID' の証明書が Keychain に見つからない。Xcode で Developer ID Application を作成してください。" >&2
  exit 1
fi

# 1. 自己完結バンドルを生成し、リリース用ディレクトリへ隔離する
#    （build-app.sh は最後に ad-hoc 署名する。隔離したコピーを以降 Developer ID で署名し直す）。
#    公開ビルドは -DORBE_DEV を焼かない（「開発中の機能を有効化」トグルの未設定 default を off にする）。
export ORBE_CHANNEL=release
"$ROOT/scripts/build-app.sh"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
/usr/bin/ditto "$BUILD_APP" "$APP"   # cp -R と違い拡張属性まで正確に複製する

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# 2. Developer ID で内側から個別署名（hardened runtime + secure timestamp）。
#    署名対象はハードコードせず、バンドル内の Mach-O を全て拾う。同梱バイナリが増えても
#    取りこぼさないため（未署名が1つでも残ると公証が Invalid で弾く）。
#    Contents/Frameworks は bundle 型 nested（XPC・Updater.app・framework 本体）を含むため
#    この flat 走査から除外し、下の bundle-aware パスで内側から署名する（flat に Mach-O 単位で
#    署名すると bundle の CodeResources 封が作られず公証が Invalid で弾く）。
echo "==> Developer ID 署名 (hardened runtime)"
while IFS= read -r bin; do
  echo "    sign: ${bin#"$APP/"}"
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$bin"
done < <(find "$APP/Contents" -path "$APP/Contents/Frameworks" -prune -o -type f -perm +111 \
           -exec sh -c 'file -b "$1" | grep -q "Mach-O"' _ {} \; -print)

# 2b. Contents/Frameworks の bundle-aware 署名（内側から）。各 framework について
#     ① 内包する bundle（*.xpc / *.app。Sparkle は Downloader/Installer XPC と Updater.app）
#     ② bundle 外の単体実行体（Sparkle の Autoupdate 等）
#     ③ framework 本体
#     の順で署名する。XPC の entitlements は上流の同梱値を保持する（--preserve-metadata）。
while IFS= read -r fw; do
  while IFS= read -r nested; do
    echo "    sign(bundle): ${nested#"$APP/"}"
    codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
      --sign "$SIGN_ID" "$nested"
  done < <(find "$fw" \( -name "*.xpc" -o -name "*.app" \) -type d)
  while IFS= read -r bin; do
    case "$bin" in */*.xpc/*|*/*.app/*) continue;; esac  # bundle 内は ① が封済み（再署名すると封が壊れる）
    echo "    sign: ${bin#"$APP/"}"
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$bin"
  done < <(find "$fw" -type f -perm +111 \
             -exec sh -c 'file -b "$1" | grep -q "Mach-O"' _ {} \; -print)
  echo "    sign(framework): ${fw#"$APP/"}"
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$fw"
done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -type d 2>/dev/null)

# 最後にバンドル本体（entitlements 付き）。
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. 公証（zip にして submit。.app 単体は submit できないため一度 zip にする）。
NOTARIZE_ZIP="$RELEASE_DIR/orbe-notarize.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
echo "==> 公証 submit"
SUBMIT_OUT="$(xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" 2>&1)"
echo "$SUBMIT_OUT"
SUB_ID="$(printf '%s\n' "$SUBMIT_OUT" | awk -F': *' '/^ *id:/{print $2; exit}')"
[ -n "$SUB_ID" ] || { echo "エラー: submission id を取得できなかった。" >&2; exit 1; }

# 完了までポーリングする（--wait は接続が切れると死ぬ。初回公証は数時間かかることがあり、
# その間のスリープ・ネットワーク瞬断を跨いで待てる必要がある）。
echo "==> 公証完了を待機 (id=$SUB_ID)"
while :; do
  INFO="$(xcrun notarytool info "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1)" \
    || { echo "    $(date '+%H:%M:%S') info失敗（一時的?）→60s後に再試行"; sleep 60; continue; }
  ST="$(printf '%s\n' "$INFO" | awk -F': *' '/^ *status:/{print $2}')"
  echo "    $(date '+%H:%M:%S') status=${ST:-unknown}"
  case "${ST:-}" in
    Accepted) break;;
    Invalid|Rejected)
      echo "エラー: 公証が通らなかった（status=${ST}）。ログ:" >&2
      xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE"
      exit 1;;
    *) sleep 60;;
  esac
done
rm -f "$NOTARIZE_ZIP"

# 4. 公証チケットを .app に添付（オフラインでも Gatekeeper が通る）。
# Accepted 直後はチケットが CDN に伝播しておらず "Record not found" で落ちるため、通るまで再試行する。
echo "==> staple"
stapled=""
for i in $(seq 1 20); do
  if xcrun stapler staple "$APP"; then stapled=1; break; fi
  echo "    チケット未伝播 → 60s後に再試行 ($i/20)"
  sleep 60
done
[ -n "$stapled" ] || { echo "エラー: staple が完了しなかった。" >&2; exit 1; }
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"

# 5. 配布用 zip（staple 済みの .app を固める。これを GitHub Releases 等に上げる）。
DIST_ZIP="$RELEASE_DIR/orbe-${VERSION}-macos.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$DIST_ZIP"

# 6. appcast.xml を生成する（Sparkle のアプリ内アップデートが読む feed。EdDSA 署名は
#    ログイン Keychain の秘密鍵で自動付与される）。最新 1 項目のみ・delta 無し（YAGNI）。
#    リリースノート: ORBE_RELEASE_NOTES=<md へのパス> で渡す（zip と同名の .md として並置すると
#    generate_appcast が description へ埋め込む。RELEASE_DIR は冒頭で作り直すため事前配置は消える）。
#    zip と appcast.xml は必ず**同じリリースのアセット**として一緒にアップロードする——
#    SUFeedURL は releases/latest/download/appcast.xml（最新リリースのアセット）を指すため、
#    載せ忘れると全クライアントの更新確認が 404 になる。
if [ -n "${ORBE_RELEASE_NOTES:-}" ] && [ -f "$ORBE_RELEASE_NOTES" ]; then
  cp "$ORBE_RELEASE_NOTES" "$RELEASE_DIR/orbe-${VERSION}-macos.md"
fi
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_appcast" ] \
  || { echo "エラー: generate_appcast が見つからない ($SPARKLE_BIN)。swift build 済みか確認せよ" >&2; exit 1; }
echo "==> appcast.xml 生成 (EdDSA 署名)"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/nakashima-takeo/orbe/releases/download/v${VERSION}/" \
  --embed-release-notes \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "$RELEASE_DIR/appcast.xml" \
  "$RELEASE_DIR"
echo "==> 完了: $DIST_ZIP"
echo "==> 完了: $RELEASE_DIR/appcast.xml (zip と同じリリースへ必ず一緒にアップロードする)"
