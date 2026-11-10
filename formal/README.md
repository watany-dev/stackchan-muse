# 形式手法(TLA+)

ファームのパッチ(`firmware/muse-stackchan.patch`)のうち、テストで網羅しにくい並行動作を TLA+ でモデル化し、TLC でモデル検査します(issue #19)。

## http_tts.tla: HTTP TTS のワーカーと会話ターン

`muse_chat_session.cpp` の hatch タスク(`start_tts()`、`http_tts_start()`、`http_tts_pump()`、`decode()`、`turn_finish()`、`on_chat_ack()` → `http_tts_warm()`)と、`http_tts_worker()` / `http_tts_speak()` が、`s_http_tts_state`・`s_http_tts_abort`・`s_http_tts_msg`・ストリームバッファ・キューを共有して動く部分のモデルです。PlusCal で書いてあり、ラベル 1 つが原子的な 1 ステップです。C の関数名やラベル名をコメントで対応させています。

抽象化したこと:

- HTTP の結果(接続失敗、HTTP エラー、読み込みのタイムアウト・切断、成功)は非決定的に選ぶ。MP3 は `Chunks` 個のチャンク
- ストリームバッファ・キュー・ターンの MP3 バッファは小さい容量の列。各要素に `<<ターン, メッセージ>>` のタグを付ける
- ターンの開始(進行中なら取り消し)、ack、返答メッセージの到着、返答の完了、取り消し・時間切れは、hatch のループ 1 周ごとに非決定的に起こす
- `http_tts_ensure_worker()` と `cJSON_PrintUnformatted()` の失敗も起こす。`ensure_worker()` は失敗しても作れたストリームバッファ・キューを残し、次回は足りない分だけ作り直す(#13)ので、モデルでは「ワーカーが起動済みか」の真偽値 1 つで表す
- 時間(タイムアウトの長さ、再生にかかる時間)は扱わない。再生は `decode()` 1 回で 1 チャンク

### 検査する性質

| 名前 | 種類 | 内容 |
|---|---|---|
| `PlayOnlyCurrent` | 安全性 | 再生される MP3 は常に今のターンの今のメッセージのもの |
| `NoResetWhileSpeaking` | 安全性 | `xStreamBufferReset()` を呼ぶとき、ワーカーは SPEAK を処理中(送信中)でない |
| `ModeDecided` | 安全性 | `s_turn.tts_msg >= 0` なら、そのメッセージは「音声あり(取得中か取得済み)」か「字幕だけ」のどちらか |
| `AtMostOneSpeak` | 安全性 | 未処理の SPEAK は同時に 1 つまで |
| `RunningMatchesWorker` | 安全性 | SPEAK が未処理なら `RUNNING`。`RUNNING` なのに SPEAK がないのは `http_tts_start()` の途中だけ |
| `RunningEnds` | 活性 | `RUNNING` はいつか終わる(`start_tts()` が `RUNNING` を見て return し続けない) |
| `ReplyResolved` | 活性 | 再生待ちになった返答メッセージは、いつか音声の再生終了か字幕表示で終わる(先にターンが終われば打ち切り) |

活性は hatch とワーカーの弱公平性を仮定しています。ワーカーの HTTP が有限時間で終わること(`timeout_ms` があること)は、チャンク数が有限であることで表しています。

### 結果

反例はありませんでした。手元の 4 コアでの時間は次のとおりです。

| 設定 | 範囲 | 性質 | 状態数 | 時間 |
|---|---|---|---|---|
| `http_tts.cfg` | 2 ターン × 2 メッセージ、2 チャンク、バッファ容量 1、キュー長 2 | 安全性と活性 | 約 35 万 | 30 秒 |
| `http_tts_3turns.cfg` | 上と同じで 3 ターン | 安全性 | 約 660 万 | 45 秒 |

issue #19 で「たぶん大丈夫」としていた次の点は、このモデルの範囲では成り立っています。

- 取り消されたターンの `HT_DONE` / `HT_FAILED` が残ったまま `http_tts_warm()` や `start_tts()` が来ても、古い音声は `xStreamBufferReset()` で捨てられ、再生されない
- `start_tts()` の `RUNNING` チェックがあるので、ワーカーが送信中に `xStreamBufferReset()` することはない
- 前のターンの音声を送っている途中で次のターンが始まっても、`s_http_tts_abort` でワーカーが抜け、古い MP3 は新しいメッセージとして再生されない
- キューが満杯で SPEAK が入らないときは、字幕だけの表示に切り替わる

モデルが空振りしていないことを、次の 2 種類の設定で確かめています(どちらも反例が出るのが正しい結果)。

- `cfg/witness_*.cfg`: 気にしている場面(キューが満杯、取り消したターンの取得終了待ち、古い音声が残ったままの開始)に実際に到達する
- `cfg/mutant_*.cfg`: `start_tts()` の `RUNNING` チェックを外すと `NoResetWhileSpeaking` が、`xStreamBufferReset()` を外すと `PlayOnlyCurrent` が破られる

## 動かし方

Java 11 以上が必要です。`check.sh` が `tla2tools.jar`(版とハッシュを固定)を `formal/.tools/` に取ってきます。

```sh
./formal/check.sh
```

CI(`.github/workflows/formal.yml`)は `formal/` かパッチが変わったときに同じスクリプトを回します。

PlusCal(`--algorithm` のコメントの中)を書き換えたら、TLA+ 部分を作り直してからコミットします。`check.sh` は作り直した結果と差分がないことも検査します。

```sh
java -cp formal/.tools/tla2tools-1.7.4.jar pcal.trans -nocfg formal/http_tts.tla
rm -f formal/http_tts.old
```

1 つの設定だけを回すとき(反例が出たら状態の列が表示されます):

```sh
cd formal
java -cp .tools/tla2tools-1.7.4.jar tlc2.TLC -workers auto -config cfg/mutant_no_reset.cfg http_tts.tla
```

## 今後

- パッチの該当箇所を変えたら、モデルも合わせて直す(CI はパッチの変更でも回るので、モデルを見直すきっかけにする)
- 反例が見つかったら、ファームのホストテスト(#17)で再現テストにする
- 同じ方法で、`muse_voice.c` の呼びかけ語 → 録音 → 静かになったら終了の状態遷移や、#13 の首コマンドをキュー化した後の動作もモデル化できる
