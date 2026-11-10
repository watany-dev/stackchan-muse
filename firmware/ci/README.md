# firmware/ci

`.github/workflows/firmware-build.yml`(ESP-IDF ビルドとメモリ回帰検知、#16)が使うスクリプトと設定です。

| ファイル | 内容 |
|---|---|
| `dummy-token.sh` | 形式だけ正しいダミーの SDK トークンを `sdkconfig.local-token` に書く。毎回同じ値 |
| `size_report.py` | `collect`: `idf.py size --format json2` とパーティション表から `metrics.json` を作る。`report`: ベースとの差分をジョブサマリに書き、しきい値を判定する |
| `memory-budget.json` | しきい値。`app_ratio_max`(アプリ bin / `ota_0`)と、バリアントごとの `diram_used_max` |
| `static_analysis.py` | パッチが足した行だけを対象に gcc `-Wall -Wextra`、cppcheck、clang-tidy、clang-format を実行する |
| `static-analysis-baseline.txt` | 静的解析の既知の指摘(失敗にしない) |
| `.clang-format` | パッチの C/C++ 用の書式。SDK に `.clang-format` がないので、パッチの書き方に近づけたもの。今は報告だけ |

## ワークフローの流れ

1. `build`(`espressif/idf:v6.0.1` コンテナ、4 バリアント)
   - `setup.sh` → ダミートークン → `build.sh` → `idf.py size` / `size-components`
   - `firmware-size-<バリアント>` という artifact に `size.json`、`metrics.json`、`size.txt`、`dependencies.lock` を上げる。`.bin` と `sdkconfig` は上げない
   - `histackchan-tts-on` だけ静的解析も行う
2. `report`
   - PR ではベースブランチの最新の artifact、main では一つ前の main の artifact と比べて、差分をジョブサマリに出す
   - `memory-budget.json` のしきい値を超えたら失敗する

バリアントは `WAKE_WORD`(`histackchan` / `himuse`)× TTS(あり / なし)です。`WAKE_WORD` に対応していない `build.sh`(日本語化 PR #1 より前)では `himuse` を飛ばします。

## しきい値を変えるとき

内部RAMを減らす変更が入ったら、ジョブサマリの DIRAM の値に 2048 を足した値を `diram_used_max` に書いて下げてください(#2/#3/#4 の省メモリ化で 180,545 → 132,045 に下げ済み)。逆に、メモリを増やす変更(例: 呼びかけ語の追加 #6)では、この値を上げることを PR の中で判断します。

## ローカルで試す

```bash
python3 firmware/ci/size_report.py collect --variant local --size-json size.json \
    --build-dir ~/.cache/stackchan-muse/build --out /tmp/m/metrics.json
python3 firmware/ci/size_report.py report --current /tmp/m --budget firmware/ci/memory-budget.json --summary ''
```
