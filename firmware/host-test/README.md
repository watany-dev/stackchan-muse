# ファームウェアのホストテスト

`firmware/src/` にある、ハードウェアに触らないコード(SCS サーボのパケット、角度の変換、`head.*` コマンドの引数検査、返答の UTF-8 切り詰め、呼びかけ語の音声のチャンク分け)を PC 上でテストします。ESP-IDF も実機もいりません(issue #17)。

`firmware/src/` のファイルは `build.sh` がビルドのたびに SDK の `esp32/main/` へコピーし、パッチ側の `stackchan_head.c` から使います。`stackchan_utf8.*` は `esp32/components/muse/` にもコピーし、`muse_chat_session.cpp` から使います。`stackchan_wake_chunk.*` も同じく `esp32/components/muse/` にコピーし、`muse_wake.c` から使います。実機で動くコードとテストするコードは同じファイルです。

## 動かし方

CMake 3.20 以降と gcc か clang が必要です。cJSON は v1.7.18 を自動で取ってきます。

```sh
cmake -S firmware/host-test -B build/host-test
cmake --build build/host-test -j
ctest --test-dir build/host-test --output-on-failure
```

既定で AddressSanitizer と UndefinedBehaviorSanitizer を有効にしてビルドします(`-DSTACKCHAN_SANITIZE=OFF` で無効)。clang の場合は ASan の実行時ライブラリ(Ubuntu なら `libclang-rt-18-dev`)が要ります。

## プロパティテスト

`prop.h` の小さな乱数ヘルパーで、毎回ちがう入力を大量に試します。

| 環境変数 | 意味 |
| --- | --- |
| `PROP_SEED` | 乱数の種。実行のたびに表示されるので、CI で落ちた入力を手元で再現できる |
| `PROP_RUNS` | プロパティごとの試行回数(既定 10000、CI は 100000) |
| `PROP_EXHAUSTIVE=1` | `deg_to_raw` を 2^32 通りすべての float で確かめる(最適化ビルドで 30 秒ほど) |

確かめている性質:

- **SCS パケット**: 組み立てたステータスパケットを解析すると同じ id・データに戻る。途中までのバイト列は「まだ足りない」になる。FF FF 以降の 1 ビット反転は必ず拒否される。FF FF を含まないノイズの後ろのパケットも見つかる。任意のバイト列で範囲外を読まない
- **角度**: 任意の float(NaN, ±Inf を含む)で `deg_to_raw` は 0〜1000。首の可動範囲では単調増加で、`raw_to_deg(deg_to_raw(d))` と `d` の差は半ステップ(0.5 / 3.2 度)以下。可動範囲の端が 0〜1000 の内側に収まる
- **コマンド引数**: 任意の JSON で、成功か `missing_param` / `invalid_param` のどちらか。`head.move` は `yaw` と `pitch` がどちらも有限の数値のときだけ通り、`duration_ms` は常に 100〜3000。`head.gesture` は 4 種類の名前以外すべて `invalid_param`
- **UTF-8 の切り詰め**(#12): 正しい UTF-8 は変わらない。任意の位置で切った文字列は、末尾(先頭)を落とすと正しい UTF-8 の接頭辞(接尾辞)になり、落とすのは 3 バイト以下。`utf8_strlcat` は容量が足りないとき文字の境界で切り、結果は常に容量未満で `strlcat` との差は 3 バイト以下。任意のバイト位置で分けて流れてきた返答を足していっても、残るのは正しい UTF-8 の接頭辞
- **呼びかけ語のチャンク分け**: WakeNet をフェイク(渡されたチャンクを記録し、決めた回で検出を返す)にして確かめる。任意の音声を任意の大きさ(0 サンプルを含む)に分けて渡し、途中で任意にリセットしても、`detect` に渡るチャンクの列と `true` を返す呼び出しが、仕様どおりに書いた参照モデルと一致する。同じ音声なら分け方によらず `detect` に渡るチャンクは同じで、最初に `true` になるのは同じチャンクを含む呼び出し。リセット後の約 1.5 秒(`24000 / チャンク長` チャンク。480 なら 50、512 なら 46)は検出しても `true` を返さず、その次からは返す。リセットは溜めかけのチャンクを捨てる。モデルがない(チャンク長 0)ときは常に `false` で `detect` も呼ばない

## ファジング

libFuzzer を使うので clang が必要です。

```sh
cmake -S firmware/host-test -B build/host-fuzz -DCMAKE_C_COMPILER=clang -DSTACKCHAN_FUZZ=ON
cmake --build build/host-fuzz -j
mkdir -p corpus && build/host-fuzz/fuzz_scs_parse corpus -max_total_time=60
build/host-fuzz/fuzz_head_cmd -max_total_time=60
```

- `fuzz_scs_parse`: 任意のバイト列を `scs_parse` に与える。受け付けたパケットは組み立て直すと元のバイト列と一致すること
- `fuzz_head_cmd`: 先頭 1 バイトでコマンドを選び、残りを JSON として引数検査に与える

CI(`.github/workflows/firmware-host-test.yml`)では、gcc と clang でのテスト、全 float の網羅チェック、各ファザー 60 秒を回します。ファザーが落ちたときは、原因の入力がアーティファクトとして保存されます。
