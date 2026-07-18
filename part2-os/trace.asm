; =================================================
; trace.asm ── デバッガの正体（第23章）
;
;   タスク1のSRのTビットを立てる。
;   すると、1命令実行するたびにトレース例外が起きる。
;
;   これが、デバッガの「ステップ実行」の正体。
;   実行した命令の番地を数え、画面に出す ＝ 簡易プロファイラ。
;
;   ビルド： vasmm68k_mot -Fbin -o trace.bin trace.asm
; =================================================

NUM_TASKS   equ     3

; --- メモリマップ（表25-1） ---
OSVars      equ     $FF0000
Tick        equ     OSVars+0        ; 2バイト：OSの時刻
CurTask     equ     OSVars+2        ; 2バイト：いま動いているタスク番号
InputEdge   equ     OSVars+4        ; 2バイト：押された瞬間のボタン
PrevPad     equ     OSVars+6        ; 2バイト：前回のパッドの状態
ErrCode     equ     OSVars+8        ; 2バイト：例外コード
ErrAddr     equ     OSVars+10       ; 4バイト：例外を起こした番地
ShowSlot    equ     OSVars+16       ; 2バイト×4：表示スロット
TraceAddr   equ     OSVars+24       ; 4バイト：最後に実行した命令の番地
TraceCount  equ     OSVars+28       ; 4バイト：実行した命令の数

TaskTable   equ     $FF0020         ; 12バイト × NUM_TASKS

KStackBase  equ     $FF0100         ; カーネルスタック（256バイト×3）
UStackBase  equ     $FF1000         ; ユーザスタック（4KB×3）

; --- タスク表のオフセット ---
T_SP        equ     0               ; 4バイト：保存されたSP（カーネル側）
T_ALIVE     equ     4               ; 1バイト：生死フラグ
T_PAD       equ     5               ; 1バイト：詰め物
T_WAKE      equ     6               ; 2バイト：起床時刻
T_USP       equ     8               ; 4バイト：保存されたUSP
T_SIZE      equ     12              ; 一行の大きさ

; =================================================
; ベクタ表
; =================================================
    org     $000000
    dc.l    $00FFFFF0           ;  0: 初期SP
    dc.l    Start               ;  1: 初期PC
    dc.l    ErrBus              ;  2: バスエラー
    dc.l    ErrAddress          ;  3: アドレスエラー
    dc.l    ErrIllegal          ;  4: 不正命令
    dc.l    ErrZeroDiv          ;  5: ゼロ除算
    dcb.l   2,ErrGeneric        ;  6-7: CHK, TRAPV
    dc.l    ErrPrivilege        ;  8: 特権違反 ← 第23章の主役
    dc.l    ErrTrace            ;  9: トレース ← 第23章の主役
    dcb.l   14,ErrGeneric       ; 10-23: その他
    dc.l    ErrGeneric          ; 24: スプリアス
    dcb.l   3,ErrGeneric        ; 25-27: レベル1〜3
    dc.l    ErrGeneric          ; 28: レベル4（HBlank）
    dc.l    ErrGeneric          ; 29: レベル5
    dc.l    VBlankPreempt       ; 30: レベル6（VBlank）← 時間の支配者
    dc.l    ErrGeneric          ; 31: レベル7
    dc.l    SysYield            ; 32: trap #0  Yield
    dc.l    SysSleep            ; 33: trap #1  Sleep
    dc.l    SysShow             ; 34: trap #2  Show
    dc.l    SysExit             ; 35: trap #3  Exit
    dc.l    SysGetInput         ; 36: trap #4  GetInput
    dcb.l   11,ErrGeneric       ; 37-47: trap #5〜#15（未使用）
    dcb.l   16,ErrGeneric       ; 48-63: 予備

; =================================================
; ROMヘッダ
; =================================================
    org     $000100
    dc.b    "SEGA MEGA DRIVE "                       ; $100 コンソール名(16)
    dc.b    "(C)MEIJIN 2026  "                       ; $110 発売元・年(16)
    dc.b    "MEIJIN TRACE DEMO                               "   ; $120 国内名(48)
    dc.b    "MEIJIN TRACE DEMO                               "   ; $150 海外名(48)
    dc.b    "GM 00000000-00"                         ; $180 シリアル(14)
    dc.w    $0000                                    ; $18E チェックサム
    dc.b    "J               "                       ; $190 対応デバイス(16)
    dc.l    $00000000,$003FFFFF                      ; $1A0 ROMの範囲
    dc.l    $00FF0000,$00FFFFFF                      ; $1A8 RAMの範囲
    dc.b    "            "                           ; $1B0 SRAM情報(12)
    dc.b    "            "                           ; $1BC 未使用(12)
    dc.b    "                                        " ; $1C8 備考(40)
    dc.b    "JUE             "                       ; $1F0 リージョン(16)

; =================================================
; 起動
; =================================================
    org     $000200
Start:
    move.w  #$2700,sr           ; 割り込みを止めて、初期化する

    move.w  #$0100,$A11100      ; Z80のバスを要求
    move.w  #$0100,$A11200      ; Z80をリセット解除

    bsr     InitVDP             ; 画面の準備（vdp.asm）
    bsr     InitPad             ; パッドの準備

    ; --- OS変数を、ゼロにする ---
    lea     OSVars,a0
    moveq   #(32/4)-1,d0
.clrvars:
    clr.l   (a0)+
    dbra    d0,.clrvars

    ; --- タスク表を、ゼロにする ---
    lea     TaskTable,a0
    moveq   #(T_SIZE*NUM_TASKS)/4-1,d0
.clrtbl:
    clr.l   (a0)+
    dbra    d0,.clrtbl

    ; --- 三人の住人を、ユーザモードで生まれさせる ---
    moveq   #0,d0
    lea     TaskClock,a2
    bsr     InitTask

    moveq   #1,d0
    lea     TaskCounter,a2
    bsr     InitTask
    bsr     SetTraceBit         ; ← タスク1に、トレースをかける

    moveq   #2,d0
    lea     TaskZombie,a2
    bsr     InitTask

    clr.w   CurTask

    ; --- タスク0を、走らせる ---
    ;     偽の履歴を rte で開封すれば、そのまま第一歩が始まる
    lea     TaskTable,a0
    move.l  T_SP(a0),sp         ; タスク0のカーネルスタックへ
    move.l  T_USP(a0),a1
    move.l  a1,usp              ; タスク0のユーザスタックを設定
    movem.l (sp)+,d0-d7/a0-a6   ; 世界を復元（全部ゼロ）
    rte                         ; ユーザモードへ落ちて、産声を上げる

; =================================================
; InitTask ── タスクの「偽の履歴」を作る（表18-4）
;   入力： d0 = タスク番号
;          a2 = タスクの入り口番地
;
;   66バイト＝レジスタ15本(60) + SR(2) + PC(4)
;   SR = $0000 ＝ ユーザモード・割り込み許可
; =================================================
InitTask:
    movem.l d0-d2/a0-a2,-(sp)

    ; --- このタスクのカーネルスタックの天井を求める ---
    move.w  d0,d1
    mulu    #256,d1
    lea     KStackBase,a1
    adda.w  d1,a1
    adda.w  #256,a1             ; a1 = カーネルスタックの天井

    suba.l  #66,a1              ; a1 = 偽のSP

    ; --- 60バイトを、ゼロで埋める ---
    move.l  a1,a0
    moveq   #15-1,d2
.zero:
    clr.l   (a0)+
    dbra    d2,.zero

    ; --- 例外フレームを偽造する（rteが消費する） ---
    move.w  #$0000,(a0)+        ; SR ＝ ユーザモード・割り込み許可
    move.l  a2,(a0)             ; 入り口番地

    ; --- タスク表に、記録する ---
    lea     TaskTable,a0
    move.w  d0,d1
    mulu    #T_SIZE,d1
    adda.w  d1,a0
    move.l  a1,T_SP(a0)         ; カーネルSP
    move.b  #1,T_ALIVE(a0)      ; 生きている
    clr.w   T_WAKE(a0)          ; 起床時刻

    ; --- ユーザスタックの天井を、記録する ---
    move.w  d0,d1
    mulu    #4096,d1
    lea     UStackBase,a1
    adda.l  d1,a1
    adda.l  #4096,a1
    move.l  a1,T_USP(a0)        ; ユーザSP

    movem.l (sp)+,d0-d2/a0-a2
    rts

; =================================================
; SetTraceBit ── タスク1の偽の履歴のSRに、Tビットを立てる
;
;   Tビット（SRのbit15）を立てると、1命令ごとに例外が起きる。
;   SRへの書き込みは特権命令なので、これができるのはOSだけ。
;   ＝ デバッグの権限は、特権である。
; =================================================
SetTraceBit:
    movem.l d0/a0-a1,-(sp)
    lea     TaskTable,a0
    move.l  T_SIZE+T_SP(a0),a1  ; タスク1の偽のSP
    move.w  #$8000,60(a1)       ; 偽の履歴のSR ＝ Tビットだけ立てる
    movem.l (sp)+,d0/a0-a1
    rts

; =================================================
; システムコールの窓口
;
;   どれも trap で呼ばれる。CPUが自動で：
;     SRを保存 → S=1 → SSPへ切替 → SR+PCを積む → ここへ飛ぶ
;   だから、入った時点でスーパーバイザモード。
; =================================================

; --- trap #0 : Yield ── CPUを譲る ---
SysYield:
    bra     Yield               ; 心臓部へ（rteで帰る）

; --- trap #1 : Sleep ── d0 = 眠るフレーム数 ---
SysSleep:
    movem.l d0-d1/a0,-(sp)

    move.w  Tick,d1             ; 起床時刻 = いまの時刻 + 眠る長さ
    add.w   d0,d1

    lea     TaskTable,a0
    move.w  CurTask,d0
    mulu    #T_SIZE,d0
    adda.w  d0,a0
    move.w  d1,T_WAKE(a0)       ; 自分の行へ書く

    movem.l (sp)+,d0-d1/a0
    bra     Yield               ; 眠りにつく ＝ CPUを譲る

; --- trap #2 : Show ── d0 = 値, d1 = スロット(0〜3) ---
SysShow:
    movem.l d0-d1/a0,-(sp)

    and.w   #3,d1               ; スロットは0〜3
    lsl.w   #1,d1               ; ×2バイト
    lea     ShowSlot,a0
    move.w  d0,(a0,d1.w)        ; 表示を予約するだけ（描くのはVBlank）

    movem.l (sp)+,d0-d1/a0
    rte

; --- trap #3 : Exit ── 自タスクを終了する ---
SysExit:
    movem.l d0/a0,-(sp)

    lea     TaskTable,a0
    move.w  CurTask,d0
    mulu    #T_SIZE,d0
    adda.w  d0,a0
    clr.b   T_ALIVE(a0)         ; 生死フラグ = 0

    movem.l (sp)+,d0/a0
    bra     Yield               ; 二度と選ばれない

; --- trap #4 : GetInput ── d0 = 押された瞬間のボタン ---
SysGetInput:
    move.w  InputEdge,d0        ; メールボックスを読んで
    clr.w   InputEdge           ; 空にする
    rte

; =================================================
; Yield ── 心臓部（全12命令）
;
;   ① 封印 ② 台帳へ ③ 次を選ぶ ④ 台帳から ⑤ 差替 ⑥ 開封 ⑦ 帰る
;
;   【割り込みの禁止について】
;   68000のtrapは、割り込みマスクを上げない。だから trap #0 で
;   ここへ来た直後にVBlankが入ると、台帳の保存が二重に走って壊れる。
;   そこで入口でマスクを7に上げ、切り替えが終わるまで割り込みを止める。
;   出口の rte が、フレームのSR（マスク0）ごと復元してくれるので、
;   タスクへ帰った瞬間に、割り込みはまた通るようになる。
; =================================================
Yield:
    ori.w   #$0700,sr           ; 割り込みを止める（切り替え中は触らせない）
    movem.l d0-d7/a0-a6,-(sp)   ; ① 世界を封印（15本を一撃で）

    lea     TaskTable,a0        ; ② 台帳へ、いまのSPを記録
    move.w  CurTask,d1
    move.w  d1,d0
    mulu    #T_SIZE,d0
    move.l  sp,(a0,d0.w)

    bsr     SwapUSP             ;    ユーザスタックも、しまう

; --- ここから下は「保存しないで切り替える」入口でもある ---
;     死んだタスクから来るときは、ここへ飛び込む（d1 = 元の番号）
SwitchNoSave:
    bsr     SelectNext          ; ③ 次を選ぶ（d0 = 選ばれた番号）

    move.w  d0,CurTask          ; ④ 台帳から引く
    mulu    #T_SIZE,d0
    move.l  (a0,d0.w),sp        ; ⑤ SPを差し替える ＝ 世界の切り替え

    bsr     LoadUSP             ;    ユーザスタックも、出す

    movem.l (sp)+,d0-d7/a0-a6   ; ⑥ 切り替わった先の世界を復元
    rte                         ; ⑦ SRごと、向こうの世界へ帰る

; -------------------------------------------------
; SwapUSP ── いまのタスクのUSPを、台帳へしまう
;   入力： d1 = いまのタスク番号
;   ※ d0 と a0 は、呼び出し側が使い続けるので壊さない
; -------------------------------------------------
SwapUSP:
    movem.l d1-d2/a0-a1,-(sp)
    move.l  usp,a1              ; USPを読む（特権命令）
    lea     TaskTable,a0
    move.w  d1,d2
    mulu    #T_SIZE,d2
    adda.w  d2,a0
    move.l  a1,T_USP(a0)
    movem.l (sp)+,d1-d2/a0-a1
    rts

; -------------------------------------------------
; LoadUSP ── 選ばれたタスクのUSPを、台帳から出す
;   入力： d0 = 番号 × T_SIZE
;   ※ d0 と a0 は、呼び出し側が使い続けるので壊さない
; -------------------------------------------------
LoadUSP:
    movem.l d0/a0-a1,-(sp)
    lea     TaskTable,a0
    adda.w  d0,a0
    move.l  T_USP(a0),a1
    move.l  a1,usp              ; USPに書く（特権命令）
    movem.l (sp)+,d0/a0-a1
    rts

; =================================================
; SelectNext ── 生きていて、起きているタスクを選ぶ
;   入力： d1 = いまのタスク番号
;   出力： d0 = 次のタスク番号
; =================================================
SelectNext:
    movem.l d1-d4/a0,-(sp)

    lea     TaskTable,a0
    move.w  d1,d0
    moveq   #NUM_TASKS-1,d4

.next:
    addq.w  #1,d0
    cmp.w   #NUM_TASKS,d0
    blo.s   .nowrap
    clr.w   d0
.nowrap:
    move.w  d0,d1
    mulu    #T_SIZE,d1

    tst.b   T_ALIVE(a0,d1.w)    ; 生きているか？
    beq.s   .skip               ; 死んでいれば、飛ばす

    move.w  Tick,d2             ; いまの時刻
    move.w  T_WAKE(a0,d1.w),d3  ; 起床時刻
    sub.w   d3,d2               ; 時刻 - 起床時刻
    bpl.s   .found              ; 0以上なら、起きている

.skip:
    dbra    d4,.next

    ; --- 誰も起きていない：いまのタスクをそのまま続ける ---
    move.w  (sp),d0             ; 退避したd1（＝元の番号）

.found:
    movem.l (sp)+,d1-d4/a0
    rts

; =================================================
; VBlankPreempt ── 時間の支配者 ＋ OSの定例業務
;
;   ここが v1.0 の要。Tickを進め、入力を読み、画面を描き、
;   そして最後に、心臓部へ飛んで時間を配り直す。
; =================================================
VBlankPreempt:
    movem.l d0-d2/a0,-(sp)

    addq.w  #1,Tick             ; OSの時刻を進める（Sleepが頼りにする）

    bsr     ReadPad             ; 入力を読んで、メールボックスへ

    ; --- 表示スロット3つを、画面へ ---
    lea     ShowSlot,a0
    move.w  (a0),d0
    moveq   #5,d1
    bsr     ShowHex

    move.w  2(a0),d0
    moveq   #7,d1
    bsr     ShowHex

    move.w  TraceCount+2,d0     ; 実行した命令の数（下位16ビット）
    moveq   #9,d1
    bsr     ShowHex

    move.w  TraceAddr+2,d0      ; 最後に実行した命令の番地
    moveq   #11,d1
    bsr     ShowHex

    ; --- 例外が起きていれば、その記録も出す ---
    move.w  ErrCode,d0
    beq.s   .noerr
    moveq   #13,d1
    bsr     ShowHex
.noerr:

    movem.l (sp)+,d0-d2/a0
    bra     Yield               ; ← 時間を取り上げ、次のタスクへ

; =================================================
; 例外ハンドラ ── 不正を「捕まえる」
; =================================================

; --- 特権違反（ベクタ8番）── 第23章の主役 ---
;     スタック： SR(2) + PC(4)
ErrPrivilege:
    move.w  #$008E,ErrCode      ; "PV" のつもり
    move.l  2(sp),ErrAddr       ; 犯人のPC（SRの2バイトを飛ばした先）
    bra     KillCurrent

; --- アドレスエラー（ベクタ3番）---
;     スタック： 特殊フレーム(8) + SR(2) + PC(4)
ErrAddress:
    move.w  #$008C,ErrCode
    move.l  10(sp),ErrAddr
    bra     KillCurrent

ErrBus:
    move.w  #$008B,ErrCode
    move.l  10(sp),ErrAddr
    bra     KillCurrent

ErrIllegal:
    move.w  #$001C,ErrCode
    move.l  2(sp),ErrAddr
    bra     KillCurrent

ErrZeroDiv:
    move.w  #$000D,ErrCode
    move.l  2(sp),ErrAddr
    bra     KillCurrent

; --- 犯人のタスクを殺して、別のタスクへ切り替える ---
;
;   注意：ここで Yield を呼んではいけない。
;   Yield は「いまのタスクのSPを台帳に保存する」ところから始まるが、
;   このタスクはもう死んでいて、二度と復元されない。
;   保存する意味がないどころか、例外フレームの残骸を書き込んでしまう。
;   だから、保存を飛ばして「選ぶところ」から始める。
KillCurrent:
    lea     TaskTable,a0
    move.w  CurTask,d1
    move.w  d1,d0
    mulu    #T_SIZE,d0
    adda.w  d0,a0
    clr.b   T_ALIVE(a0)         ; 生死フラグ = 0

    lea     TaskTable,a0        ; a0を戻す
    bra     SwitchNoSave        ; 保存せずに、次のタスクへ

; --- トレース（ベクタ9番）── デバッガの正体・後編 ---
;     Tビットが立っていると、1命令ごとにここへ来る。
;
;     スタック（この時点）：
;       movemで退避した3本(12) + SR(2) + PC(4)
;     だから、PCは 2+12 = 14(sp) にある。
ErrTrace:
    movem.l d0-d1/a0,-(sp)      ; 3本 ＝ 12バイト

    move.l  2+12(sp),d0         ; いま実行し終わった命令の、次の番地
    move.l  d0,TraceAddr
    addq.l  #1,TraceCount       ; 実行した命令の数を数える

    movem.l (sp)+,d0-d1/a0
    rte                         ; 次の1命令へ

ErrGeneric:
    rte

; =================================================
; パッド入力
; =================================================
PAD_DATA    equ     $A10003
PAD_CTRL    equ     $A10009

InitPad:
    move.b  #$40,PAD_CTRL       ; THを出力に
    move.b  #$40,PAD_DATA
    rts

ReadPad:
    movem.l d0-d2,-(sp)

    move.b  #$40,PAD_DATA       ; TH=1
    nop
    nop
    move.b  PAD_DATA,d0         ; Start/A/C/B/右/左/下/上
    and.w   #$7F,d0
    not.w   d0                  ; 押下=1 に反転
    and.w   #$7F,d0

    move.w  PrevPad,d1
    not.w   d1
    and.w   d0,d1               ; エッジ = 今回 ∧ ¬前回

    move.w  InputEdge,d2
    or.w    d1,d2
    move.w  d2,InputEdge        ; メールボックスへ積む

    move.w  d0,PrevPad

    movem.l (sp)+,d0-d2
    rts

; =================================================
; アプリたち（ユーザモードで動く）
;
;   システムコールしか使わない。
;   VDPも、タイマーも、パッドも、直接は触らない。
; =================================================

; --- タスク0：時計。1秒に一回、数える ---
TaskClock:
    moveq   #0,d2
.loop:
    addq.w  #1,d2

    move.w  d2,d0
    moveq   #0,d1
    trap    #2                  ; Show(値, スロット0)

    move.w  #60,d0
    trap    #1                  ; Sleep(60フレーム = 1秒)

    bra.s   .loop

; --- タスク1：Aボタンを押した回数を数える ---
TaskCounter:
    moveq   #0,d2
.loop:
    trap    #4                  ; GetInput
    btst    #6,d0               ; Aボタンか？
    beq.s   .show
    addq.w  #1,d2
.show:
    move.w  d2,d0
    moveq   #1,d1
    trap    #2                  ; Show(値, スロット1)

    trap    #0                  ; 礼儀正しく譲る
    bra.s   .loop

; --- タスク2：ゾンビ。譲らない ---
TaskZombie:
    moveq   #0,d2
.loop:
    addq.w  #1,d2

    move.w  d2,d0
    moveq   #2,d1
    trap    #2                  ; Show(値, スロット2)

    bra.s   .loop               ; 譲らない

; =================================================
; 部品
; =================================================
    include "vdp.asm"
    include "font.asm"

    end     Start
