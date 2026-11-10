------------------------------ MODULE http_tts ------------------------------
(***************************************************************************)
(* HTTP TTS(firmware/muse-stackchan.patch の muse_chat_session.cpp)の     *)
(* hatch タスクと http_tts ワーカーの並行動作のモデル。                    *)
(*                                                                         *)
(* hatch タスク: hatch_task() のループ 1 周を、外部イベント 1 つ           *)
(*   (ターン開始・ack・メッセージ到着・返答完了・取り消し)の処理と、      *)
(*   start_tts() → http_tts_pump() → decode() → check_turn() で表す。      *)
(* ワーカー: http_tts_worker() / http_tts_speak()。HTTP の結果(成功・失敗・ *)
(*   タイムアウト)は非決定的に選び、MP3 は Chunks 個のチャンクに抽象化する。*)
(*                                                                         *)
(* ストリームバッファ・キュー・ターンの MP3 バッファは列で表し、各要素に   *)
(* <<ターン番号, メッセージ番号>> のタグを付けて、どのメッセージの音声かを *)
(* 追跡する。C の s_http_tts_msg / s_turn.tts_msg は 0 始まりで「なし」が  *)
(* -1 だが、モデルでは 1 始まりで「なし」を 0 (NoMsg) にしている。         *)
(*                                                                         *)
(* PlusCal の各ラベルが 1 つの原子的なステップ。hatch 側の関数は途中で     *)
(* ワーカーが割り込めるよう、共有状態に触る単位でラベルを分けている。      *)
(*                                                                         *)
(* PlusCal を編集したら pcal.trans で TLA+ 部分を再生成すること            *)
(* (formal/check.sh が再生成結果との差分を検査する)。                      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Turns,         \* ターン数の上限
    Msgs,          \* 1 ターンの返答メッセージ数の上限
    Chunks,        \* 1 メッセージの MP3 のチャンク数
    SBCap,         \* ストリームバッファ s_http_tts_sb の容量(チャンク数)
    QCap,          \* キュー s_http_tts_q の長さ(C では 2)
    MP3Cap,        \* ターンの MP3 バッファ s_turn.mp3 の容量(チャンク数)
    CheckRunning,  \* start_tts() の「RUNNING なら return」(変異テストでは FALSE)
    ResetBuffer    \* http_tts_start() の xStreamBufferReset()(変異テストでは FALSE)

ASSUME /\ Turns \in Nat \ {0}
       /\ Msgs \in Nat \ {0}
       /\ Chunks \in Nat
       /\ SBCap \in Nat \ {0}
       /\ QCap \in Nat \ {0}
       /\ MP3Cap \in Nat \ {0}
       /\ CheckRunning \in BOOLEAN
       /\ ResetBuffer \in BOOLEAN

NoMsg == 0
MsgIds == 1..Msgs
Min(a, b) == IF a < b THEN a ELSE b

(* --algorithm http_tts

variables
    \* ---- 共有状態 ----
    state = "IDLE",       \* s_http_tts_state: IDLE / RUNNING / DONE / FAILED
    abort = FALSE,        \* s_http_tts_abort
    httpMsg = NoMsg,      \* s_http_tts_msg
    sb = <<>>,            \* s_http_tts_sb(要素はタグ)
    q = <<>>,             \* s_http_tts_q(要素は [kind, tag])
    workerUp = FALSE,     \* http_tts_ensure_worker() が成功済み(s_http_tts_q != NULL)
    \* ---- hatch タスクだけが触る状態(s_turn) ----
    turn = 0,             \* 何ターン目か(ゴースト兼用)
    phase = "idle",       \* idle / listen(ack 待ち)/ wait(P_WAIT_REPLY)
    isText = FALSE,       \* s_turn.text(文字入力のターンはウォームアップしない)
    tts = [m \in MsgIds |-> "none"],  \* msgs[m].tts: none / queued / active / finished
    ttsMsg = NoMsg,       \* s_turn.tts_msg
    silent = FALSE,       \* s_turn.silent(字幕だけの表示)
    mp3Ended = FALSE,     \* s_turn.mp3_ended
    mp3 = <<>>,           \* s_turn.mp3(要素はタグ)
    replyDone = FALSE,    \* 返答がすべて届いた(check_turn() の終了条件を抽象化)
    \* ---- ゴースト(性質を書くためだけの変数)----
    queued = [t \in 1..Turns |-> [m \in MsgIds |-> FALSE]],    \* そのメッセージが再生待ちになった
    result = [t \in 1..Turns |-> [m \in MsgIds |-> "none"]],   \* none / audio / caption / cut
    resetWhileSpeaking = FALSE;  \* ワーカーが SPEAK 処理中に xStreamBufferReset() した

define
    \* ワーカーが SPEAK を処理している間のラベル(送信中を含む)
    SpeakLabels == {"W_open", "W_read", "W_send", "W_done"}
    WorkerSpeaking == pc["worker"] \in SpeakLabels
    SpeakInQueue == \E i \in 1..Len(q) : q[i].kind = "speak"
    NSpeakInQueue == Cardinality({i \in 1..Len(q) : q[i].kind = "speak"})

    Tags == (1..Turns) \X MsgIds

    TypeOK ==
        /\ state \in {"IDLE", "RUNNING", "DONE", "FAILED"}
        /\ abort \in BOOLEAN
        /\ httpMsg \in MsgIds \cup {NoMsg}
        /\ sb \in Seq(Tags) /\ Len(sb) <= SBCap
        /\ q \in Seq([kind : {"warm", "speak"}, tag : Tags \cup {<<0, 0>>}]) /\ Len(q) <= QCap
        /\ workerUp \in BOOLEAN
        /\ turn \in 0..Turns
        /\ phase \in {"idle", "listen", "wait"}
        /\ tts \in [MsgIds -> {"none", "queued", "active", "finished"}]
        /\ ttsMsg \in MsgIds \cup {NoMsg}
        /\ mp3 \in Seq(Tags) /\ Len(mp3) <= MP3Cap

    (***********************************************************************)
    (* 安全性                                                              *)
    (***********************************************************************)

    \* 再生される音声は、常に今のターンの今のメッセージのもの。古い MP3 が
    \* 新しいメッセージとして再生されない。decode() が MP3 バッファを再生するのは
    \* 字幕だけの表示(silent)でないときなので、そのときのバッファの中身を見る。
    \* (字幕に切り替わったメッセージの途中までの MP3 は、次に音声ありで始める
    \* ときに mp3_len = 0 で捨てられるまで残るが、再生はされない)
    PlayOnlyCurrent ==
        (phase = "wait" /\ ttsMsg # NoMsg /\ ~silent) =>
            \A i \in 1..Len(mp3) : mp3[i] = <<turn, ttsMsg>>

    \* xStreamBufferReset() を呼ぶとき、ワーカーは SPEAK を処理中(送信中)でない。
    \* (FreeRTOS ではバッファで待っているタスクがいるとリセットが失敗する)
    NoResetWhileSpeaking == ~resetWhileSpeaking

    \* s_turn.tts_msg >= 0 のとき、そのメッセージは「音声あり」か「字幕だけ」の
    \* どちらかに決まっている。音声ありなら、リレーからまだ受け取っている途中
    \* (s_http_tts_msg == tts_msg)か、受け取り終わっている(mp3_ended)。
    ModeDecided ==
        ttsMsg # NoMsg =>
            /\ tts[ttsMsg] = "active"
            /\ \/ silent
               \/ httpMsg = ttsMsg
               \/ mp3Ended

    \* 未処理の SPEAK は同時に 1 つまで。
    AtMostOneSpeak ==
        NSpeakInQueue + (IF WorkerSpeaking THEN 1 ELSE 0) <= 1

    \* SPEAK が未処理なら state は RUNNING。RUNNING なのに SPEAK がないのは、
    \* http_tts_start() が RUNNING にしてからキューに入れるまでの間だけ。
    RunningMatchesWorker ==
        /\ (SpeakInQueue \/ WorkerSpeaking) => state = "RUNNING"
        /\ state = "RUNNING" =>
               \/ SpeakInQueue \/ WorkerSpeaking
               \/ pc["hatch"] = "H_send"

    (***********************************************************************)
    (* 活性(hatch とワーカーの弱公平性を仮定)                            *)
    (***********************************************************************)

    \* start_tts() が RUNNING を見て return し続ける状態に永遠に留まらない。
    RunningEnds == state = "RUNNING" ~> state # "RUNNING"

    \* 返答メッセージが再生待ちになったら、いつかは再生終了か字幕表示で終わる
    \* (その前にターンが取り消されたら "cut")。
    ReplyResolved ==
        \A t \in 1..Turns, m \in MsgIds :
            queued[t][m] ~> result[t][m] # "none"

    (***********************************************************************)
    (* 到達性の確認用(「破られる」ことを期待する不変条件)。               *)
    (* モデルが空振りしていない(気にしている場面に実際に到達する)ことを   *)
    (* 確かめるために使う。check.sh はこれらが反例を出すことを検査する。   *)
    (***********************************************************************)

    \* キューが満杯で SPEAK が入らず、字幕だけの表示に切り替わる場面
    NeverQueueFull == ~(pc["hatch"] = "H_send" /\ Len(q) = QCap)

    \* 取り消したターンの取得が終わるのを、次のターンの start_tts() が待つ場面
    NeverWaitStaleRunning ==
        ~(/\ pc["hatch"] = "H_pump"
          /\ phase = "wait" /\ ttsMsg = NoMsg
          /\ \E m \in MsgIds : tts[m] = "queued"
          /\ state = "RUNNING" /\ httpMsg = NoMsg)

    \* 取り消したターンの音声がバッファに残ったまま、次の http_tts_start() が来る場面
    NeverStaleDataAtReset ==
        ~(pc["hatch"] = "H_reset" /\ \E i \in 1..Len(sb) : sb[i][1] # turn)
end define;

\* turn_finish() の HTTP TTS に関わる部分。
macro turn_finish() begin
    abort := TRUE;
    httpMsg := NoMsg;
    phase := "idle";
    ttsMsg := NoMsg;
    result[turn] := [m \in MsgIds |->
                        IF result[turn][m] = "none" /\ queued[turn][m]
                        THEN "cut" ELSE result[turn][m]];
end macro;

fair process hatch = "hatch"
variables m0 = NoMsg, st = "IDLE";
begin
H_loop:
    while TRUE do
        \* ---- 外部イベントを 1 つ処理する(handle(cmd) / poll_socket())----
        either
            \* turn_start(): 進行中のターンがあれば先に turn_finish()
            await turn < Turns;
            if phase # "idle" then
                turn_finish();
            end if;
        H_begin:
            turn := turn + 1;
            phase := "listen";
            tts := [m \in MsgIds |-> "none"];
            ttsMsg := NoMsg;
            silent := FALSE;
            mp3Ended := FALSE;
            mp3 := <<>>;
            replyDone := FALSE;
            with t \in BOOLEAN do isText := t; end with;
        or
            \* on_chat_ack(): 声のターンなら http_tts_warm()
            await phase = "listen";
            phase := "wait";
            if ~isText /\ state # "RUNNING" then
                \* http_tts_ensure_worker() は失敗することがある(作れた分は残し、足りない分を次回作り直す。#13)
                either
                    await ~workerUp;
                or
                    workerUp := TRUE;
                    \* xQueueSend(..., 0): 満杯なら捨てる
                    if Len(q) < QCap then
                        q := Append(q, [kind |-> "warm", tag |-> <<0, 0>>]);
                    end if;
                end either;
            end if;
        or
            \* 返答メッセージが届き終わった(msg_done → TTS_QUEUED)
            await phase = "wait" /\ ~replyDone;
            with m \in {k \in MsgIds : tts[k] = "none"} do
                tts[m] := "queued";
                queued[turn][m] := TRUE;
            end with;
        or
            \* 返答がすべて届いた
            await phase = "wait" /\ ~replyDone /\ \E k \in MsgIds : tts[k] # "none";
            replyDone := TRUE;
        or
            \* 取り消し・時間切れ・失敗(CMD_CANCEL / turn_fail / turn_done(false))
            await phase # "idle";
            turn_finish();
        or
            skip;
        end either;

        \* ---- start_tts() ----
    H_tts:
        if phase = "wait" /\ ttsMsg = NoMsg /\ \E k \in MsgIds : tts[k] = "queued" then
            m0 := CHOOSE k \in MsgIds : tts[k] = "queued" /\ \A j \in MsgIds : j < k => tts[j] # "queued";
            if CheckRunning /\ state = "RUNNING" then
                goto H_pump;   \* a cancelled turn's fetch is still winding down
            else
                \* ---- http_tts_start(m0) ----
                either
                    await ~workerUp;   \* http_tts_ensure_worker() 失敗
                    goto H_caption;
                or
                    workerUp := TRUE;
                end either;
            end if;
        else
            goto H_pump;
        end if;
    H_reset:
        \* xStreamBufferReset(s_http_tts_sb)
        resetWhileSpeaking := resetWhileSpeaking \/ WorkerSpeaking;
        if ResetBuffer then
            sb := <<>>;
        end if;
        \* cJSON_PrintUnformatted() は失敗することがある
        either goto H_caption; or skip; end either;
    H_arm:
        abort := FALSE;
        httpMsg := m0;
        state := "RUNNING";
    H_send:
        if Len(q) < QCap then
            q := Append(q, [kind |-> "speak", tag |-> <<turn, m0>>]);
            \* start_tts(): 音声ありで開始
            tts[m0] := "active";
            ttsMsg := m0;
            silent := FALSE;
            mp3Ended := FALSE;
            mp3 := <<>>;
            goto H_pump;
        else
            \* キューが満杯: 取り消して false を返す
            state := "IDLE";
            httpMsg := NoMsg;
        end if;
    H_caption:
        \* start_tts(): 字幕だけで開始
        tts[m0] := "active";
        ttsMsg := m0;
        silent := TRUE;

        \* ---- http_tts_pump() ----
    H_pump:
        if phase = "wait" /\ ttsMsg # NoMsg /\ ~silent /\ ~mp3Ended /\ httpMsg = ttsMsg then
            st := state;
        H_drain:
            \* MP3 バッファに空きがある分だけ受け取る(tts_data)
            with n = Min(MP3Cap - Len(mp3), Len(sb)) do
                mp3 := mp3 \o SubSeq(sb, 1, n);
                sb := SubSeq(sb, n + 1, Len(sb));
            end with;
        H_pcheck:
            if st # "RUNNING" /\ sb = <<>> then
                httpMsg := NoMsg;
                state := "IDLE";
                if st = "DONE" then
                    mp3Ended := TRUE;
                else
                    silent := TRUE;   \* リレーが失敗: 字幕だけの表示に切り替える
                end if;
            end if;
        end if;

        \* ---- decode() / pace_silently() ----
    H_decode:
        if phase = "wait" /\ ttsMsg # NoMsg then
            if silent then
                tts[ttsMsg] := "finished";
                result[turn][ttsMsg] := "caption";
                ttsMsg := NoMsg;
                silent := FALSE;
            elsif mp3 # <<>> then
                \* 1 チャンク分を再生する。届き終わっていて空になればメッセージ終了
                mp3 := Tail(mp3);
                if mp3Ended /\ mp3 = <<>> then
                    tts[ttsMsg] := "finished";
                    result[turn][ttsMsg] := "audio";
                    ttsMsg := NoMsg;
                end if;
            elsif mp3Ended then
                tts[ttsMsg] := "finished";
                result[turn][ttsMsg] := "audio";
                ttsMsg := NoMsg;
            end if;
        end if;

        \* ---- check_turn(): 返答が届き終わり、全部話し終えたらターン終了 ----
    H_check:
        if phase = "wait" /\ replyDone /\ \A k \in MsgIds : tts[k] \notin {"queued", "active"} then
            turn_finish();
        end if;
    end while;
end process;

fair process worker = "worker"
variables req = [kind |-> "warm", tag |-> <<0, 0>>], left = 0, ok = FALSE;
begin
W_recv:
    while TRUE do
        \* xQueueReceive(s_http_tts_q, &req, portMAX_DELAY)
        await workerUp /\ q # <<>>;
        req := Head(q);
        q := Tail(q);
        if req.kind = "warm" then
        W_warm:
            \* GET /tts で接続だけ開く。成否は共有状態に影響しない
            skip;
        else
            left := Chunks;
            ok := FALSE;
        W_open:
            \* open / write / fetch_headers(再接続 1 回込み)と HTTP ステータス
            either goto W_done; or skip; end either;
        W_read:
            while TRUE do
                \* esp_http_client_read()
                either
                    goto W_done;   \* n < 0(タイムアウト・切断)、または不完全な終端
                or
                    if abort then
                        goto W_done;
                    elsif left = 0 then
                        ok := TRUE;   \* n == 0 かつ全部受け取った
                        goto W_done;
                    end if;
                end either;
            W_send:
                \* while (off < n && !abort) xStreamBufferSend(..., 100 ms)
                await Len(sb) < SBCap \/ abort;
                if ~abort then
                    sb := Append(sb, req.tag);
                    left := left - 1;
                end if;
            end while;
        W_done:
            \* free(req.body); s_http_tts_state = ok ? HT_DONE : HT_FAILED
            state := IF ok THEN "DONE" ELSE "FAILED";
        end if;
    end while;
end process;

end algorithm; *)
\* BEGIN TRANSLATION (chksum(pcal) = "7b8af6" /\ chksum(tla) = "8ca36ad6")
VARIABLES state, abort, httpMsg, sb, q, workerUp, turn, phase, isText, tts, 
          ttsMsg, silent, mp3Ended, mp3, replyDone, queued, result, 
          resetWhileSpeaking, pc

(* define statement *)
SpeakLabels == {"W_open", "W_read", "W_send", "W_done"}
WorkerSpeaking == pc["worker"] \in SpeakLabels
SpeakInQueue == \E i \in 1..Len(q) : q[i].kind = "speak"
NSpeakInQueue == Cardinality({i \in 1..Len(q) : q[i].kind = "speak"})

Tags == (1..Turns) \X MsgIds

TypeOK ==
    /\ state \in {"IDLE", "RUNNING", "DONE", "FAILED"}
    /\ abort \in BOOLEAN
    /\ httpMsg \in MsgIds \cup {NoMsg}
    /\ sb \in Seq(Tags) /\ Len(sb) <= SBCap
    /\ q \in Seq([kind : {"warm", "speak"}, tag : Tags \cup {<<0, 0>>}]) /\ Len(q) <= QCap
    /\ workerUp \in BOOLEAN
    /\ turn \in 0..Turns
    /\ phase \in {"idle", "listen", "wait"}
    /\ tts \in [MsgIds -> {"none", "queued", "active", "finished"}]
    /\ ttsMsg \in MsgIds \cup {NoMsg}
    /\ mp3 \in Seq(Tags) /\ Len(mp3) <= MP3Cap










PlayOnlyCurrent ==
    (phase = "wait" /\ ttsMsg # NoMsg /\ ~silent) =>
        \A i \in 1..Len(mp3) : mp3[i] = <<turn, ttsMsg>>



NoResetWhileSpeaking == ~resetWhileSpeaking




ModeDecided ==
    ttsMsg # NoMsg =>
        /\ tts[ttsMsg] = "active"
        /\ \/ silent
           \/ httpMsg = ttsMsg
           \/ mp3Ended


AtMostOneSpeak ==
    NSpeakInQueue + (IF WorkerSpeaking THEN 1 ELSE 0) <= 1



RunningMatchesWorker ==
    /\ (SpeakInQueue \/ WorkerSpeaking) => state = "RUNNING"
    /\ state = "RUNNING" =>
           \/ SpeakInQueue \/ WorkerSpeaking
           \/ pc["hatch"] = "H_send"






RunningEnds == state = "RUNNING" ~> state # "RUNNING"



ReplyResolved ==
    \A t \in 1..Turns, m \in MsgIds :
        queued[t][m] ~> result[t][m] # "none"








NeverQueueFull == ~(pc["hatch"] = "H_send" /\ Len(q) = QCap)


NeverWaitStaleRunning ==
    ~(/\ pc["hatch"] = "H_pump"
      /\ phase = "wait" /\ ttsMsg = NoMsg
      /\ \E m \in MsgIds : tts[m] = "queued"
      /\ state = "RUNNING" /\ httpMsg = NoMsg)


NeverStaleDataAtReset ==
    ~(pc["hatch"] = "H_reset" /\ \E i \in 1..Len(sb) : sb[i][1] # turn)

VARIABLES m0, st, req, left, ok

vars == << state, abort, httpMsg, sb, q, workerUp, turn, phase, isText, tts, 
           ttsMsg, silent, mp3Ended, mp3, replyDone, queued, result, 
           resetWhileSpeaking, pc, m0, st, req, left, ok >>

ProcSet == {"hatch"} \cup {"worker"}

Init == (* Global variables *)
        /\ state = "IDLE"
        /\ abort = FALSE
        /\ httpMsg = NoMsg
        /\ sb = <<>>
        /\ q = <<>>
        /\ workerUp = FALSE
        /\ turn = 0
        /\ phase = "idle"
        /\ isText = FALSE
        /\ tts = [m \in MsgIds |-> "none"]
        /\ ttsMsg = NoMsg
        /\ silent = FALSE
        /\ mp3Ended = FALSE
        /\ mp3 = <<>>
        /\ replyDone = FALSE
        /\ queued = [t \in 1..Turns |-> [m \in MsgIds |-> FALSE]]
        /\ result = [t \in 1..Turns |-> [m \in MsgIds |-> "none"]]
        /\ resetWhileSpeaking = FALSE
        (* Process hatch *)
        /\ m0 = NoMsg
        /\ st = "IDLE"
        (* Process worker *)
        /\ req = [kind |-> "warm", tag |-> <<0, 0>>]
        /\ left = 0
        /\ ok = FALSE
        /\ pc = [self \in ProcSet |-> CASE self = "hatch" -> "H_loop"
                                        [] self = "worker" -> "W_recv"]

H_loop == /\ pc["hatch"] = "H_loop"
          /\ \/ /\ turn < Turns
                /\ IF phase # "idle"
                      THEN /\ abort' = TRUE
                           /\ httpMsg' = NoMsg
                           /\ phase' = "idle"
                           /\ ttsMsg' = NoMsg
                           /\ result' = [result EXCEPT ![turn] = [m \in MsgIds |->
                                                                     IF result[turn][m] = "none" /\ queued[turn][m]
                                                                     THEN "cut" ELSE result[turn][m]]]
                      ELSE /\ TRUE
                           /\ UNCHANGED << abort, httpMsg, phase, ttsMsg, 
                                           result >>
                /\ pc' = [pc EXCEPT !["hatch"] = "H_begin"]
                /\ UNCHANGED <<q, workerUp, tts, replyDone, queued>>
             \/ /\ phase = "listen"
                /\ phase' = "wait"
                /\ IF ~isText /\ state # "RUNNING"
                      THEN /\ \/ /\ ~workerUp
                                 /\ UNCHANGED <<q, workerUp>>
                              \/ /\ workerUp' = TRUE
                                 /\ IF Len(q) < QCap
                                       THEN /\ q' = Append(q, [kind |-> "warm", tag |-> <<0, 0>>])
                                       ELSE /\ TRUE
                                            /\ q' = q
                      ELSE /\ TRUE
                           /\ UNCHANGED << q, workerUp >>
                /\ pc' = [pc EXCEPT !["hatch"] = "H_tts"]
                /\ UNCHANGED <<abort, httpMsg, tts, ttsMsg, replyDone, queued, result>>
             \/ /\ phase = "wait" /\ ~replyDone
                /\ \E m \in {k \in MsgIds : tts[k] = "none"}:
                     /\ tts' = [tts EXCEPT ![m] = "queued"]
                     /\ queued' = [queued EXCEPT ![turn][m] = TRUE]
                /\ pc' = [pc EXCEPT !["hatch"] = "H_tts"]
                /\ UNCHANGED <<abort, httpMsg, q, workerUp, phase, ttsMsg, replyDone, result>>
             \/ /\ phase = "wait" /\ ~replyDone /\ \E k \in MsgIds : tts[k] # "none"
                /\ replyDone' = TRUE
                /\ pc' = [pc EXCEPT !["hatch"] = "H_tts"]
                /\ UNCHANGED <<abort, httpMsg, q, workerUp, phase, tts, ttsMsg, queued, result>>
             \/ /\ phase # "idle"
                /\ abort' = TRUE
                /\ httpMsg' = NoMsg
                /\ phase' = "idle"
                /\ ttsMsg' = NoMsg
                /\ result' = [result EXCEPT ![turn] = [m \in MsgIds |->
                                                          IF result[turn][m] = "none" /\ queued[turn][m]
                                                          THEN "cut" ELSE result[turn][m]]]
                /\ pc' = [pc EXCEPT !["hatch"] = "H_tts"]
                /\ UNCHANGED <<q, workerUp, tts, replyDone, queued>>
             \/ /\ TRUE
                /\ pc' = [pc EXCEPT !["hatch"] = "H_tts"]
                /\ UNCHANGED <<abort, httpMsg, q, workerUp, phase, tts, ttsMsg, replyDone, queued, result>>
          /\ UNCHANGED << state, sb, turn, isText, silent, mp3Ended, mp3, 
                          resetWhileSpeaking, m0, st, req, left, ok >>

H_tts == /\ pc["hatch"] = "H_tts"
         /\ IF phase = "wait" /\ ttsMsg = NoMsg /\ \E k \in MsgIds : tts[k] = "queued"
               THEN /\ m0' = (CHOOSE k \in MsgIds : tts[k] = "queued" /\ \A j \in MsgIds : j < k => tts[j] # "queued")
                    /\ IF CheckRunning /\ state = "RUNNING"
                          THEN /\ pc' = [pc EXCEPT !["hatch"] = "H_pump"]
                               /\ UNCHANGED workerUp
                          ELSE /\ \/ /\ ~workerUp
                                     /\ pc' = [pc EXCEPT !["hatch"] = "H_caption"]
                                     /\ UNCHANGED workerUp
                                  \/ /\ workerUp' = TRUE
                                     /\ pc' = [pc EXCEPT !["hatch"] = "H_reset"]
               ELSE /\ pc' = [pc EXCEPT !["hatch"] = "H_pump"]
                    /\ UNCHANGED << workerUp, m0 >>
         /\ UNCHANGED << state, abort, httpMsg, sb, q, turn, phase, isText, 
                         tts, ttsMsg, silent, mp3Ended, mp3, replyDone, queued, 
                         result, resetWhileSpeaking, st, req, left, ok >>

H_reset == /\ pc["hatch"] = "H_reset"
           /\ resetWhileSpeaking' = (resetWhileSpeaking \/ WorkerSpeaking)
           /\ IF ResetBuffer
                 THEN /\ sb' = <<>>
                 ELSE /\ TRUE
                      /\ sb' = sb
           /\ \/ /\ pc' = [pc EXCEPT !["hatch"] = "H_caption"]
              \/ /\ TRUE
                 /\ pc' = [pc EXCEPT !["hatch"] = "H_arm"]
           /\ UNCHANGED << state, abort, httpMsg, q, workerUp, turn, phase, 
                           isText, tts, ttsMsg, silent, mp3Ended, mp3, 
                           replyDone, queued, result, m0, st, req, left, ok >>

H_arm == /\ pc["hatch"] = "H_arm"
         /\ abort' = FALSE
         /\ httpMsg' = m0
         /\ state' = "RUNNING"
         /\ pc' = [pc EXCEPT !["hatch"] = "H_send"]
         /\ UNCHANGED << sb, q, workerUp, turn, phase, isText, tts, ttsMsg, 
                         silent, mp3Ended, mp3, replyDone, queued, result, 
                         resetWhileSpeaking, m0, st, req, left, ok >>

H_send == /\ pc["hatch"] = "H_send"
          /\ IF Len(q) < QCap
                THEN /\ q' = Append(q, [kind |-> "speak", tag |-> <<turn, m0>>])
                     /\ tts' = [tts EXCEPT ![m0] = "active"]
                     /\ ttsMsg' = m0
                     /\ silent' = FALSE
                     /\ mp3Ended' = FALSE
                     /\ mp3' = <<>>
                     /\ pc' = [pc EXCEPT !["hatch"] = "H_pump"]
                     /\ UNCHANGED << state, httpMsg >>
                ELSE /\ state' = "IDLE"
                     /\ httpMsg' = NoMsg
                     /\ pc' = [pc EXCEPT !["hatch"] = "H_caption"]
                     /\ UNCHANGED << q, tts, ttsMsg, silent, mp3Ended, mp3 >>
          /\ UNCHANGED << abort, sb, workerUp, turn, phase, isText, replyDone, 
                          queued, result, resetWhileSpeaking, m0, st, req, 
                          left, ok >>

H_caption == /\ pc["hatch"] = "H_caption"
             /\ tts' = [tts EXCEPT ![m0] = "active"]
             /\ ttsMsg' = m0
             /\ silent' = TRUE
             /\ pc' = [pc EXCEPT !["hatch"] = "H_pump"]
             /\ UNCHANGED << state, abort, httpMsg, sb, q, workerUp, turn, 
                             phase, isText, mp3Ended, mp3, replyDone, queued, 
                             result, resetWhileSpeaking, m0, st, req, left, ok >>

H_pump == /\ pc["hatch"] = "H_pump"
          /\ IF phase = "wait" /\ ttsMsg # NoMsg /\ ~silent /\ ~mp3Ended /\ httpMsg = ttsMsg
                THEN /\ st' = state
                     /\ pc' = [pc EXCEPT !["hatch"] = "H_drain"]
                ELSE /\ pc' = [pc EXCEPT !["hatch"] = "H_decode"]
                     /\ st' = st
          /\ UNCHANGED << state, abort, httpMsg, sb, q, workerUp, turn, phase, 
                          isText, tts, ttsMsg, silent, mp3Ended, mp3, 
                          replyDone, queued, result, resetWhileSpeaking, m0, 
                          req, left, ok >>

H_drain == /\ pc["hatch"] = "H_drain"
           /\ LET n == Min(MP3Cap - Len(mp3), Len(sb)) IN
                /\ mp3' = mp3 \o SubSeq(sb, 1, n)
                /\ sb' = SubSeq(sb, n + 1, Len(sb))
           /\ pc' = [pc EXCEPT !["hatch"] = "H_pcheck"]
           /\ UNCHANGED << state, abort, httpMsg, q, workerUp, turn, phase, 
                           isText, tts, ttsMsg, silent, mp3Ended, replyDone, 
                           queued, result, resetWhileSpeaking, m0, st, req, 
                           left, ok >>

H_pcheck == /\ pc["hatch"] = "H_pcheck"
            /\ IF st # "RUNNING" /\ sb = <<>>
                  THEN /\ httpMsg' = NoMsg
                       /\ state' = "IDLE"
                       /\ IF st = "DONE"
                             THEN /\ mp3Ended' = TRUE
                                  /\ UNCHANGED silent
                             ELSE /\ silent' = TRUE
                                  /\ UNCHANGED mp3Ended
                  ELSE /\ TRUE
                       /\ UNCHANGED << state, httpMsg, silent, mp3Ended >>
            /\ pc' = [pc EXCEPT !["hatch"] = "H_decode"]
            /\ UNCHANGED << abort, sb, q, workerUp, turn, phase, isText, tts, 
                            ttsMsg, mp3, replyDone, queued, result, 
                            resetWhileSpeaking, m0, st, req, left, ok >>

H_decode == /\ pc["hatch"] = "H_decode"
            /\ IF phase = "wait" /\ ttsMsg # NoMsg
                  THEN /\ IF silent
                             THEN /\ tts' = [tts EXCEPT ![ttsMsg] = "finished"]
                                  /\ result' = [result EXCEPT ![turn][ttsMsg] = "caption"]
                                  /\ ttsMsg' = NoMsg
                                  /\ silent' = FALSE
                                  /\ mp3' = mp3
                             ELSE /\ IF mp3 # <<>>
                                        THEN /\ mp3' = Tail(mp3)
                                             /\ IF mp3Ended /\ mp3' = <<>>
                                                   THEN /\ tts' = [tts EXCEPT ![ttsMsg] = "finished"]
                                                        /\ result' = [result EXCEPT ![turn][ttsMsg] = "audio"]
                                                        /\ ttsMsg' = NoMsg
                                                   ELSE /\ TRUE
                                                        /\ UNCHANGED << tts, 
                                                                        ttsMsg, 
                                                                        result >>
                                        ELSE /\ IF mp3Ended
                                                   THEN /\ tts' = [tts EXCEPT ![ttsMsg] = "finished"]
                                                        /\ result' = [result EXCEPT ![turn][ttsMsg] = "audio"]
                                                        /\ ttsMsg' = NoMsg
                                                   ELSE /\ TRUE
                                                        /\ UNCHANGED << tts, 
                                                                        ttsMsg, 
                                                                        result >>
                                             /\ mp3' = mp3
                                  /\ UNCHANGED silent
                  ELSE /\ TRUE
                       /\ UNCHANGED << tts, ttsMsg, silent, mp3, result >>
            /\ pc' = [pc EXCEPT !["hatch"] = "H_check"]
            /\ UNCHANGED << state, abort, httpMsg, sb, q, workerUp, turn, 
                            phase, isText, mp3Ended, replyDone, queued, 
                            resetWhileSpeaking, m0, st, req, left, ok >>

H_check == /\ pc["hatch"] = "H_check"
           /\ IF phase = "wait" /\ replyDone /\ \A k \in MsgIds : tts[k] \notin {"queued", "active"}
                 THEN /\ abort' = TRUE
                      /\ httpMsg' = NoMsg
                      /\ phase' = "idle"
                      /\ ttsMsg' = NoMsg
                      /\ result' = [result EXCEPT ![turn] = [m \in MsgIds |->
                                                                IF result[turn][m] = "none" /\ queued[turn][m]
                                                                THEN "cut" ELSE result[turn][m]]]
                 ELSE /\ TRUE
                      /\ UNCHANGED << abort, httpMsg, phase, ttsMsg, result >>
           /\ pc' = [pc EXCEPT !["hatch"] = "H_loop"]
           /\ UNCHANGED << state, sb, q, workerUp, turn, isText, tts, silent, 
                           mp3Ended, mp3, replyDone, queued, 
                           resetWhileSpeaking, m0, st, req, left, ok >>

H_begin == /\ pc["hatch"] = "H_begin"
           /\ turn' = turn + 1
           /\ phase' = "listen"
           /\ tts' = [m \in MsgIds |-> "none"]
           /\ ttsMsg' = NoMsg
           /\ silent' = FALSE
           /\ mp3Ended' = FALSE
           /\ mp3' = <<>>
           /\ replyDone' = FALSE
           /\ \E t \in BOOLEAN:
                isText' = t
           /\ pc' = [pc EXCEPT !["hatch"] = "H_tts"]
           /\ UNCHANGED << state, abort, httpMsg, sb, q, workerUp, queued, 
                           result, resetWhileSpeaking, m0, st, req, left, ok >>

hatch == H_loop \/ H_tts \/ H_reset \/ H_arm \/ H_send \/ H_caption
            \/ H_pump \/ H_drain \/ H_pcheck \/ H_decode \/ H_check
            \/ H_begin

W_recv == /\ pc["worker"] = "W_recv"
          /\ workerUp /\ q # <<>>
          /\ req' = Head(q)
          /\ q' = Tail(q)
          /\ IF req'.kind = "warm"
                THEN /\ pc' = [pc EXCEPT !["worker"] = "W_warm"]
                     /\ UNCHANGED << left, ok >>
                ELSE /\ left' = Chunks
                     /\ ok' = FALSE
                     /\ pc' = [pc EXCEPT !["worker"] = "W_open"]
          /\ UNCHANGED << state, abort, httpMsg, sb, workerUp, turn, phase, 
                          isText, tts, ttsMsg, silent, mp3Ended, mp3, 
                          replyDone, queued, result, resetWhileSpeaking, m0, 
                          st >>

W_warm == /\ pc["worker"] = "W_warm"
          /\ TRUE
          /\ pc' = [pc EXCEPT !["worker"] = "W_recv"]
          /\ UNCHANGED << state, abort, httpMsg, sb, q, workerUp, turn, phase, 
                          isText, tts, ttsMsg, silent, mp3Ended, mp3, 
                          replyDone, queued, result, resetWhileSpeaking, m0, 
                          st, req, left, ok >>

W_open == /\ pc["worker"] = "W_open"
          /\ \/ /\ pc' = [pc EXCEPT !["worker"] = "W_done"]
             \/ /\ TRUE
                /\ pc' = [pc EXCEPT !["worker"] = "W_read"]
          /\ UNCHANGED << state, abort, httpMsg, sb, q, workerUp, turn, phase, 
                          isText, tts, ttsMsg, silent, mp3Ended, mp3, 
                          replyDone, queued, result, resetWhileSpeaking, m0, 
                          st, req, left, ok >>

W_read == /\ pc["worker"] = "W_read"
          /\ \/ /\ pc' = [pc EXCEPT !["worker"] = "W_done"]
                /\ ok' = ok
             \/ /\ IF abort
                      THEN /\ pc' = [pc EXCEPT !["worker"] = "W_done"]
                           /\ ok' = ok
                      ELSE /\ IF left = 0
                                 THEN /\ ok' = TRUE
                                      /\ pc' = [pc EXCEPT !["worker"] = "W_done"]
                                 ELSE /\ pc' = [pc EXCEPT !["worker"] = "W_send"]
                                      /\ ok' = ok
          /\ UNCHANGED << state, abort, httpMsg, sb, q, workerUp, turn, phase, 
                          isText, tts, ttsMsg, silent, mp3Ended, mp3, 
                          replyDone, queued, result, resetWhileSpeaking, m0, 
                          st, req, left >>

W_send == /\ pc["worker"] = "W_send"
          /\ Len(sb) < SBCap \/ abort
          /\ IF ~abort
                THEN /\ sb' = Append(sb, req.tag)
                     /\ left' = left - 1
                ELSE /\ TRUE
                     /\ UNCHANGED << sb, left >>
          /\ pc' = [pc EXCEPT !["worker"] = "W_read"]
          /\ UNCHANGED << state, abort, httpMsg, q, workerUp, turn, phase, 
                          isText, tts, ttsMsg, silent, mp3Ended, mp3, 
                          replyDone, queued, result, resetWhileSpeaking, m0, 
                          st, req, ok >>

W_done == /\ pc["worker"] = "W_done"
          /\ state' = IF ok THEN "DONE" ELSE "FAILED"
          /\ pc' = [pc EXCEPT !["worker"] = "W_recv"]
          /\ UNCHANGED << abort, httpMsg, sb, q, workerUp, turn, phase, isText, 
                          tts, ttsMsg, silent, mp3Ended, mp3, replyDone, 
                          queued, result, resetWhileSpeaking, m0, st, req, 
                          left, ok >>

worker == W_recv \/ W_warm \/ W_open \/ W_read \/ W_send \/ W_done

Next == hatch \/ worker

Spec == /\ Init /\ [][Next]_vars
        /\ WF_vars(hatch)
        /\ WF_vars(worker)

\* END TRANSLATION 
=============================================================================
