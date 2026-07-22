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
echo "==> Developer ID 署名 (hardened runtime)"
while IFS= read -r bin; do
  echo "    sign: ${bin#"$APP/"}"
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$bin"
done < <(find "$APP/Contents" -type f -perm +111 \
           -exec sh -c 'file -b "$1" | grep -q "Mach-O"' _ {} \; -print)

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
echo "==> 完了: $DIST_ZIP"
