# stackchan-muse

M5Stack **スタックチャン**(CoreS3)の工場出荷 AI を Meta の **Muse** に置き換え、首の動き・日本語字幕・音声での返答・「Hi, Muse」の呼びかけ語を加えるコードです。

このリポジトリは [nobaksan/stackchan-muse](https://github.com/nobaksan/stackchan-muse)(韓国の書籍『피지컬 AI 실전』18章「Muse로 말하는 StackChan」の実習コード)を日本語向けに手直ししたフォークです。

Turns an M5Stack StackChan (CoreS3) into a [Muse](https://gadgets.muse.ai/) gadget with its neck servos as Muse commands, Japanese captions, spoken replies through a small TTS relay, and a "Hi, Muse" wake word ("Hi, Stack Chan" as an option). Built as a patch on Meta's [Muse Gadget SDK](https://github.com/facebookincubator/muse-gadget-sdk). A Japanese-oriented fork of nobaksan/stackchan-muse.

```
「ハイ、ミューズ。うなずいて」
   │ ESP-SR WakeNet(機器の中で判定)
   ▼
スタックチャン ──音声──▶ Muse(Meta のサーバー)──head.gesture──▶ スタックチャンの首サーボ
スタックチャン ◀──返答の文字── Muse
スタックチャン ──文字──▶ tts-relay(自分のサーバー)──MP3──▶ スタックチャンのスピーカー + 日本語字幕
```

## 中身

| パス | 内容 |
|---|---|
| `firmware/muse-stackchan.patch` | Muse Gadget SDK(`b139b45`)に当てる変更。17ファイル |
| `firmware/*.sh` | バックアップ → 準備 → ビルド → 書き込み → 復元のスクリプト |
| `tts-relay/` | Muse の文字の返答を MP3 にする小さなサーバー(Python、edge-tts) |

パッチが SDK に加えるもの:

| 機能 | ファイル | 設定 |
|---|---|---|
| 首のコマンド `head.move`、`head.gesture`、`head.get` | `esp32/main/stackchan_head.c` | `CONFIG_HOMEHUB_STACKCHAN_HEAD` |
| 日本語字幕(SDK の CJK フォント。かな・漢字入り。ハングルは任意) | `tools/muse/gen_cjk_font.sh` | `CONFIG_MUSE_CJK_FONT` |
| 返答を音声で(HTTP の TTS 中継) | `components/muse/muse_chat_session.cpp` | `CONFIG_MUSE_HTTP_TTS` |
| 呼びかけ語「Hi, Muse」(esp-sr `wn10_himuse`)。「Hi, Stack Chan」(`wn9l_histackchan_tts3`)にも切り替え可 | `components/muse/muse_wake.c`、`muse_voice.c` | `CONFIG_MUSE_WAKE_WORD` |
| 上の設定をまとめたボード設定、`model` パーティション | `devices/sdkconfig.muse-stackchan`、`partitions_muse_stackchan.csv` | |

SDK 本体はこのリポジトリに入っていません。`setup.sh` が Meta のリポジトリから取得します。

## 始める前に

- **Muse は 2026年10月時点で米国でのみ提供されています。** 米国の Muse 契約アカウントと、スマートフォン(iOS/Android)の Muse アプリが必要です。日本からの利用や、日本語の音声認識・返答にどこまで対応しているかは確認できていません。
- **SDK トークン**: <https://gadgets.muse.ai/settings/sdk-tokens> にログインして発行します。有効なトークンはアカウントごとに1つ、個人・非商用に限ります([Gadget SDK Terms](https://gadgets.muse.ai/sdk-terms))。
- ハードウェア: **M5Stack スタックチャン公式版(CoreS3)**。ほかのボードでは試していません。
- **工場出荷のファームウェアは消えます。** 必ず最初に `backup.sh` を実行してください。

## 準備(macOS の場合)

```bash
brew install cmake ninja dfu-util
python3 -m pip install esptool

# ESP-IDF 6.0.1(SDK が対応している唯一の版)
git clone -b v6.0.1 --recursive --depth 1 --shallow-submodules \
    https://github.com/espressif/esp-idf.git ~/.espressif/esp-idf-v6.0.1
~/.espressif/esp-idf-v6.0.1/install.sh esp32s3
```

別の場所に入れた場合は `IDF_EXPORT=/パス/export.sh` を指定します。ハングル入りの字幕フォントを作るときだけ Node.js(`brew install node`)も必要です。

## 実行

データ転送に対応した USB-C ケーブルでスタックチャンをつないで:

```bash
git clone https://github.com/watany-dev/stackchan-muse
cd stackchan-muse/firmware

./backup.sh                      # 1. 16MB 全体のバックアップと検証。Wi-Fi のパスワードが入るので公開しないこと
./setup.sh                       # 2. SDK の取得とパッチの適用

cp sdkconfig.local-token.example sdkconfig.local-token
#                                  3. sdkconfig.local-token に mgst_ で始まるトークンを書く

./build.sh                       # 4. ビルド(初回は3〜5分ほど)
./flash.sh                       # 5. 機器に書き込む
./monitor.sh                     #    ログを見る(Ctrl-] で終了)
```

ポートは自動で探します。複数ある場合は `PORT=/dev/cu.usbmodem1101 ./flash.sh` のように指定します。

### 設定の切り替え

| 変数 | 既定 | 内容 |
|---|---|---|
| `WAKE_WORD` | `himuse` | 呼びかけ語。`himuse`(Hi, Muse)か `histackchan`(Hi, Stack Chan)。`WAKE_WORD=histackchan ./build.sh` |
| `FONT_HANGUL` | `0` | `1` にすると字幕フォントにハングルを加える(フラッシュを約450KB使う)。`FONT_HANGUL=1 ./setup.sh` |

呼びかけ語は1つだけ有効にできます。両方を同時に聞き取る対応は、メモリの余裕を実機で確かめてから検討します。

### ペアリング

1. スマートフォンの Muse アプリ → 設定 → デバイス → **開発者モード**をオン(Web からはデバイスを追加できません)
2. **+** → `MuseGadget-XXXXXX` → 接続 → コミュニティデバイスの警告で「無視して続ける」
3. スタックチャンの左側面の **PWR ボタンを短く1回**押すと、アプリの確認ボタンが押せるようになります
4. Wi-Fi を選べば完了です。ログに `setup=done wifi=up ws=up` が出ます

### 使ってみる

- PWR ボタンを押しながら話すか、**「ハイ、ミューズ」**(英語風に「Hi, Muse」)と呼んでから話します。話し終えて0.9秒たつと自動で送られます。
- 「うなずいて」「左を見て」「今の首の角度を教えて」
- スマートフォンのチャット画面に文字で書いても動きます。

## 返答を音声で聞く(任意)

Muse がガジェットに送るのは文字だけです。音声で聞くには `tts-relay` を HTTPS で立て、ファームウェアに URL とキーを設定します。

**サーバー**(Linux。例: `/opt/stackchan-tts`):

```bash
cd tts-relay
python3 -m venv .venv && .venv/bin/pip install --require-hashes -r requirements.txt
cp .env.example .env && echo "TTS_KEY=$(openssl rand -hex 24)" >> .env   # .env はコミットされません
set -a && . ./.env && set +a         # server.py は .env を読まないので環境変数にする
.venv/bin/python server.py            # 127.0.0.1:3710 だけで待ち受けます
```

- 試す: `curl -X POST http://127.0.0.1:3710/tts -H "X-TTS-Key: <キー>" -H 'Content-Type: application/json' -d '{"text":"こんにちは"}' -o a.mp3`
- テスト: `.venv/bin/pip install -r requirements-dev.txt && .venv/bin/pytest`(edge-tts はスタブにするのでネットワークは使いません)
- 返すステータス: キー違いは 401、本文がおかしいときは 400、edge-tts が音声を返せなかったときは 502。`TTS_KEY` が空・16 バイト未満のときは起動しません
- 常時動かす: `stackchan-tts.service`(systemd)。公開: `nginx.conf.example`(HTTPS、リクエスト制限、`proxy_buffering off`)
- 声は文字の種類で選びます。かなを含めば `ja-JP-NanamiNeural`、ハングルを含めば `ko-KR-SunHiNeural`、漢字だけなら `TTS_DEFAULT_LANG`(既定 `ja`)、それ以外は `en-US-AriaNeural`。声は `.env` の `TTS_VOICE_JA` などで変えられます。出力は MP3 24kHz 48kbps モノラル。
- edge-tts は Microsoft Edge のオンライン読み上げを使う非公式のライブラリです。予告なく使えなくなる可能性があります。

**ファームウェア**:

```bash
cd firmware
cp sdkconfig.local-tts.example sdkconfig.local-tts   # URL と TTS_KEY を書く
./build.sh && ./flash.sh
```

中継が失敗したときは字幕だけを表示します。

## 既知の問題

元のリポジトリで書籍の執筆時に実測した値です(2026-10-07、韓国語・「Hi, Stack Chan」の構成、**esp-sr 2.5.5**)。日本語・「Hi, Muse」での実測はまだです。今のパッチは esp-sr 2.6.1 / esp-dl 3.3.15 に固定しているので([依存の版](#依存の版))、内部 RAM の数値はこの表と変わりえます。

| 問題 | 状態 |
|---|---|
| 話し終えてから音が出るまで25秒以上。そのうち20秒ほどは Muse のサーバーが返答を作る時間 | モデルや速度はガジェット側から変えられない |
| スタックチャンが TTS を受け取り始めるまで4.3〜4.7秒(サーバー側は0.3秒。接続を使い回しても同じ) | **原因未確認** |
| 呼びかけ語の最初の呼びかけを聞き逃すことがある。認識率・誤認識率は未測定 | 未測定。「Hi, Muse」(WakeNet10)でも未測定 |
| 呼びかけ語を入れると内部 RAM の空きが27KB(最低14KB)。TTS の接続が一度すぐに失敗する | メモリ不足の疑い、未確認。WakeNet10 での値は未測定。登録後は BLE を起動せずメモリを返すようにした(#5、実機での効果は未測定)。そのため設定メニューの「Phone setup」を ON にすると1回再起動する |
| バッテリー駆動で画面が消えると SDK がマイクを止めるので、呼びかけ語も聞こえない | SDK の動作。USB 給電でのみ試験 |
| esp-sr 2.5.5 の wn9l の `clean()` が NULL を読んでパニックする | 呼ばずに、録音後1.5秒の検出を無視して回避 |
| 作業パスに日本語など ASCII 以外の文字があると、コンパイラが spec ファイルのパスを読めない | `BUILD_DIR` を英数字だけのパス(既定 `~/.cache/stackchan-muse/build`)にして解決 |
| 音声なしで字幕だけを流すときの速さはバイト数で決まるので、日本語(1文字3バイト)は英語よりゆっくり流れる | SDK の動作。未対応 |

## 依存の版

ビルドする時期で結果やメモリの数値が変わらないよう、依存の版を固定しています(#7)。

| 対象 | 固定している場所 |
|---|---|
| Muse Gadget SDK | `firmware/env.sh` の `SDK_REV`(コミット) |
| ESP-IDF | v6.0.1(`firmware/env.sh`、CI のコンテナ `espressif/idf:v6.0.1`) |
| ESP-IDF コンポーネント(esp-sr、esp-dl、LVGL など) | パッチが入れる `esp32/dependencies.lock`。esp-sr は `idf_component.yml` でも `2.6.1` ちょうどを指定 |
| tts-relay(Python) | `tts-relay/requirements.txt`(間接依存まで、ハッシュ付き) |

`build.sh` はビルド中に `dependencies.lock` が書き換わると警告します(CI では失敗にします)。版を上げるときは:

- **ESP-IDF コンポーネント**: SDK の `idf_component.yml` を書き換えて `./build.sh` を実行し、書き換わった lock ごとパッチを作り直します。lock は SDK の `.gitignore` に入っているので、`git -C muse-gadget-sdk add -f esp32/dependencies.lock` で index に入れると、`git diff HEAD` で作るパッチに含まれます。上げたあとは実機で動作とメモリを確かめ、「既知の問題」の数値と版を書き直します。
- **tts-relay**: `requirements.in` の版を変えて、`requirements.txt` の先頭に書いてある `uv pip compile ...` のコマンドで作り直します。

## 元に戻す

```bash
./restore.sh stackchan_backup_YYYYMMDD_HHMMSS.bin
```

スマートフォンのアプリのデバイス一覧に残った `MuseGadget-...` は手で削除し、必要なら SDK トークンを Revoke します。

## 秘密の情報

トークンと TTS のキーは `sdkconfig.local-token`、`sdkconfig.local-tts`、`tts-relay/.env` にだけ置きます。3つとも `.gitignore` に入っています。トークンはファームウェアのバイナリに埋め込まれるので、ビルド結果(`.bin`)とバックアップファイルも公開しないでください。

## ライセンス

Apache License 2.0。依存するソフトウェアの出典とライセンスは [NOTICE](NOTICE) にあります。Meta、M5Stack、Espressif とは関係のない個人のプロジェクトです。
