#!/usr/bin/env bash
# formal/ の TLA+ モデルを TLC で検査する(issue #19)。CI と手元の両方で使う。
#
#   ./formal/check.sh            # tla2tools.jar を formal/.tools/ に取ってきて全部回す
#   TLA2TOOLS=/path/to/tla2tools.jar ./formal/check.sh
#
# 1. PlusCal から生成した TLA+ 部分が最新か(pcal.trans で作り直して差分を見る)
# 2. http_tts.cfg(2 ターン、安全性と活性)と http_tts_3turns.cfg(3 ターン、安全性):
#    反例が出ないこと
# 3. cfg/witness_*.cfg: 気にしている場面に実際に到達すること(反例が出ること)
# 4. cfg/mutant_*.cfg: わざと壊した版で、性質が破られると検出できること(反例が出ること)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TLA_VERSION="1.7.4"
TLA_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
TLA2TOOLS="${TLA2TOOLS:-$HERE/.tools/tla2tools-$TLA_VERSION.jar}"

# TLC の終了コード(tlc2.output.EC.ExitStatus)
EXIT_OK=0
EXIT_SAFETY=12

if [ ! -f "$TLA2TOOLS" ]; then
    mkdir -p "$(dirname "$TLA2TOOLS")"
    curl -fsSL -o "$TLA2TOOLS.tmp" \
        "https://github.com/tlaplus/tlaplus/releases/download/v$TLA_VERSION/tla2tools.jar"
    echo "$TLA_SHA256  $TLA2TOOLS.tmp" | sha256sum -c -
    mv "$TLA2TOOLS.tmp" "$TLA2TOOLS"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tlc() {
    # $1: 設定ファイル(formal/ からの相対パス)
    java -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC \
        -workers auto -cleanup -metadir "$WORK/states" \
        -config "$1" http_tts.tla
}

failed=0

echo "::group::PlusCal translation is up to date"
cp "$HERE/http_tts.tla" "$WORK/"
(cd "$WORK" && java -cp "$TLA2TOOLS" pcal.trans -nocfg http_tts.tla >/dev/null)
if diff -u "$HERE/http_tts.tla" "$WORK/http_tts.tla"; then
    echo "ok"
else
    echo "::error file=formal/http_tts.tla::PlusCal から生成した部分が古い。pcal.trans で作り直してコミットする"
    failed=1
fi
echo "::endgroup::"

# $1: 設定ファイル、$2: 期待する終了コード、$3: 期待するメッセージ(反例のとき)
run() {
    local cfg="$1" want="$2" pattern="${3:-}" log code
    log="$WORK/$(basename "$cfg").log"
    echo "::group::$cfg (expect exit $want)"
    set +e
    (cd "$HERE" && tlc "$cfg") >"$log" 2>&1
    code=$?
    set -e
    grep -E "violated|Error:|states generated|Finished in|No error" "$log" || true
    echo "::endgroup::"
    if [ "$code" -ne "$want" ] || { [ -n "$pattern" ] && ! grep -q "$pattern" "$log"; }; then
        echo "::error file=formal/$cfg::exit $code (expected $want)"
        cat "$log"
        failed=1
    else
        echo "ok: $cfg"
    fi
}

run http_tts.cfg "$EXIT_OK" "No error has been found"
run http_tts_3turns.cfg "$EXIT_OK" "No error has been found"
for cfg in "$HERE"/cfg/*.cfg; do
    cfg="cfg/$(basename "$cfg")"
    inv="$(sed -n 's/^INVARIANT[S]* *//p' "$HERE/$cfg")"
    run "$cfg" "$EXIT_SAFETY" "Invariant $inv is violated"
done

exit "$failed"
