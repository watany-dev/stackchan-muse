#!/usr/bin/env bash
# CI 用のダミー SDK トークンを sdkconfig.local-token に書き出す。
# 形式は build.sh / SDK の validate_config.cmake と同じ(mgst_ + base64url 43 文字)。
# 本物のトークンではないのでペアリングはできないが、ビルドとサイズ計測には十分。
# 毎回同じ値にして、生成物のサイズがトークンでぶれないようにしている。
set -euo pipefail
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/sdkconfig.local-token}"

body="CIdummyTokenNotARealMuseSdkToken" # 32 文字
while [ ${#body} -lt 42 ]; do body="${body}0"; done
token="mgst_${body}A" # 最後の 1 文字は base64url の末尾として正しいもの

printf 'CONFIG_GADGET_SDK_TOKEN="%s"\n' "$token" >"$OUT"
grep -Eq '^CONFIG_GADGET_SDK_TOKEN="mgst_[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]"$' "$OUT"
echo "Wrote dummy token to $OUT"
