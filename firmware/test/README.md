# firmware/*.sh のテスト

[bats-core](https://github.com/bats-core/bats-core) と bats-assert で、`firmware/*.sh` の分岐を実機なしで確かめます。esptool・idf.py・`ls`(ポート探索)などは PATH の先頭に置いたスタブで、呼ばれ方を記録します。SDK は手元に作る偽のリポジトリ(`SDK_REPO=file://...`)を使うので、ネットワークも ESP-IDF も要りません。

スクリプトはテストごとに空白を含むディレクトリ(`.../My Projects/firmware`)へコピーして実行するので、パスの引用漏れもすべてのテストで同時に確かめています。

## 実行

```sh
# macOS
brew install bats-core bats-core/bats-core/bats-support bats-core/bats-core/bats-assert
export BATS_LIB_PATH="$(brew --prefix)/lib"

bats firmware/test
```

Linux では bats-core・bats-support・bats-assert を clone して、その親ディレクトリを `BATS_LIB_PATH` に入れてください。トークンのテストには `cmake` が要ります(なければスキップ)。

## トークンのプロパティテスト

`build.sh` のトークン検査は、SDK の `esp32/cmake/validate_config.cmake` の規則を grep で書き直したものです。`build.bats` はランダムに作ったトークン(正しい形式、1文字足りない/多い、最後の文字が不正、base64url 以外の文字、prefix の崩れ、任意の長さ)を、SDK の規則をそのまま写した `sdk_token_rule.cmake` と `build.sh` の両方に流し、判定が一致することを確かめます。

- `TOKEN_SAMPLES`: 件数(既定 200、CI は 500)
- `TOKEN_SEED`: 乱数の種。失敗したときのメッセージに出るので、同じ値で再現できます

SDK の版(`env.sh` の `SDK_REV`)を上げたら、`sdk_token_rule.cmake` の `if()` を新しい SDK からコピーし直してください。

## PR #1 の機能

`WAKE_WORD`(`build.sh`)と `FONT_HANGUL`(`setup.sh`)のテストは、スクリプトにその変数が入るまでスキップされ、PR #1 がマージされると自動的に有効になります。
