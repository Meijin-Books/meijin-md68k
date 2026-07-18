; =================================================
; coop.asm ── MeijinOS68k v0.1（協調的マルチタスク）
;   二つのタスクが、自分から順番を譲り合って動く
;
;   ビルド： vasmm68k_mot -Fbin -o coop.bin coop.asm
;   実行  ： BlastEm に coop.bin を放り込む
;
;   期待する結果：
;     上の行と下の行に、同じ値が並んで増えていく（2A = 2A）
;     ＝ 二つのタスクが、きっちり交代で動いている証拠
;
;   【注意】この版では、まだユーザモードを使っていない。
;           全員がスーパーバイザモードで動く。
;           特権の境界は、第18章（meijin10.asm）で導入する。
; =================================================

NUM_TASKS   equ     2

; --- メモリマップ（表25-1） ---
OSVars      equ     $FF0000
Tick        equ     OSVars+0        ; 2バイト：OSの時刻
CurTask     equ     OSVars+2        ; 2バイト：いま動いているタスク番号
CounterA    equ     OSVars+4        ; 2バイト：タスクAのカウンタ
CounterB    equ     OSVars+6        ; 2バイト：タスクBのカウンタ
VBlankFlag  equ     OSVars+8        ; 2バイト：VBlankが来た印

TaskTable   equ     $FF0020         ; 8バイト × NUM_TASKS

StackA_Top  equ     $FF2000         ; タスク0のスタック（天井）
StackB_Top  equ     $FF3000         ; タスク1のスタック（天井）

; --- タスク表のオフセット（表15-1） ---
T_SP        equ     0               ; 4バイト：保存されたSP
T_ALIVE     equ     4               ; 1バイト：生死フラグ
T_PAD       equ     5               ; 1バイト：詰め物
T_WAKE      equ     6               ; 2バイト：起床時刻
T_SIZE      equ     8               ; 一行の大きさ

; =================================================
; ベクタ表（ROMの先頭256バイト）
; =================================================
    org     $000000
    dc.l    $00FFFFF0           ;  0: 初期SP（スーパーバイザ用）
    dc.l    Start               ;  1: 初期PC（リセット）
    dc.l    ErrGeneric          ;  2: バスエラー
    dc.l    ErrGeneric          ;  3: アドレスエラー
    dc.l    ErrGeneric          ;  4: 不正命令
    dc.l    ErrGeneric          ;  5: ゼロ除算
    dcb.l   2,ErrGeneric        ;  6-7: CHK, TRAPV
    dc.l    ErrGeneric          ;  8: 特権違反
    dc.l    ErrGeneric          ;  9: トレース
    dcb.l   14,ErrGeneric       ; 10-23: その他
    dc.l    ErrGeneric          ; 24: スプリアス割り込み
    dcb.l   3,ErrGeneric        ; 25-27: レベル1〜3
    dc.l    ErrGeneric          ; 28: レベル4（HBlank）
    dc.l    ErrGeneric          ; 29: レベル5
    dc.l    VBlankHandler       ; 30: レベル6（VBlank）← 画面の反映
    dc.l    ErrGeneric          ; 31: レベル7
    dc.l    SysYield            ; 32: trap #0 ← 譲る玄関
    dcb.l   15,ErrGeneric       ; 33-47: trap #1〜#15（未使用）
    dcb.l   16,ErrGeneric       ; 48-63: 予備

; =================================================
; ROMヘッダ
; =================================================
    org     $000100
    dc.b    "SEGA MEGA DRIVE "                       ; $100 コンソール名(16)
    dc.b    "(C)MEIJIN 2026  "                       ; $110 発売元・年(16)
    dc.b    "MEIJIN OS68K V0.1                               "   ; $120 国内名(48)
    dc.b    "MEIJIN OS68K V0.1                               "   ; $150 海外名(48)
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

    ; --- Z80とVDPを、最小限だけ黙らせる ---
    move.w  #$0100,$A11100      ; Z80のバスを要求
    move.w  #$0100,$A11200      ; Z80をリセット解除

    bsr     InitVDP             ; 画面の準備（vdp.asm）

    ; --- OS変数を、ゼロにする ---
    lea     OSVars,a0
    moveq   #8-1,d0
.clrvars:
    clr.l   (a0)+
    dbra    d0,.clrvars

    ; --- タスク表を、ゼロにする ---
    lea     TaskTable,a0
    moveq   #(T_SIZE*NUM_TASKS)/4-1,d0
.clrtbl:
    clr.l   (a0)+
    dbra    d0,.clrtbl

    ; --- タスク1（B）の「偽の履歴」を作る ---
    moveq   #1,d0
    lea     StackB_Top,a1
    lea     TaskB,a2
    bsr     InitTask

    ; --- タスク0（A）の行を、埋めておく ---
    ;     Aは「いま走っている本人」なので、SPの保存は不要。
    ;     最初のYieldのときに、自分で書き込む。
    lea     TaskTable,a0
    move.b  #1,T_ALIVE(a0)      ; 生きている

    clr.w   CurTask             ; タスク0から始める

    ; --- そのまま、タスクAになる ---
    move.w  #$2000,sr           ; 割り込みを許可（S=1, マスク=0）
    lea     StackA_Top,sp
    bra     TaskA

; =================================================
; InitTask ── タスクの「偽の履歴」を作る（表16-2）
;   入力： d0 = タスク番号
;          a1 = スタックの天井
;          a2 = タスクの入り口番地
;
;   66バイト＝レジスタ15本(60) + SR(2) + 戻り先PC(4)
;   Yieldはrteで帰るので、例外フレームまで偽造する
; =================================================
InitTask:
    movem.l d0-d2/a0-a2,-(sp)

    suba.l  #66,a1              ; a1 = 偽のSP

    ; --- 60バイトを、ゼロで埋める ---
    move.l  a1,a0
    moveq   #15-1,d2            ; 15本ぶん
.zero:
    clr.l   (a0)+
    dbra    d2,.zero

    ; --- 例外フレーム（SR+PC）を偽造する ＝ rte が消費する ---
    move.w  #$2000,(a0)+        ; SR ＝ S=1・割り込み許可
    move.l  a2,(a0)             ; 入り口番地 ＝ ここへ rte が飛ぶ

    ; --- タスク表に、記録する ---
    lea     TaskTable,a0
    move.w  d0,d1
    mulu    #T_SIZE,d1
    adda.w  d1,a0
    move.l  a1,T_SP(a0)         ; 保存されたSP
    move.b  #1,T_ALIVE(a0)      ; 生きている
    clr.w   T_WAKE(a0)          ; 起床時刻

    movem.l (sp)+,d0-d2/a0-a2
    rts

; =================================================
; SysYield ── trap #0 のハンドラ
;
;   trap が積んだフレーム： SR(2) + PC(4) = 6バイト
;   Yield は「今のスタックの続き」で世界を封印し、
;   最後に rte で、そのフレームごと帰る。
;   だから bsr ではなく bra で飛ぶ（戻ってこない）。
; =================================================
SysYield:
    bra     Yield

; =================================================
; Yield ── 心臓部（全13命令）
;
;   ① レジスタを封印   ② 台帳へ記録   ③ 次を選ぶ
;   ④ 台帳から引く     ⑤ SPを差し替え ⑥ 開封  ⑦ 帰る
; =================================================
Yield:
    ori.w   #$0700,sr           ; 割り込みを止める（切り替え中は触らせない）
    movem.l d0-d7/a0-a6,-(sp)   ; ① 世界を封印（15本を一撃で）

    lea     TaskTable,a0        ; ② 台帳へ、いまのSPを記録
    move.w  CurTask,d1
    move.w  d1,d0
    lsl.w   #3,d0               ;    番号 × 8
    move.l  sp,(a0,d0.w)

    bsr     SelectNext          ; ③ 次を選ぶ（d0 = 選ばれた番号）

    move.w  d0,CurTask          ; ④ 台帳から引く
    lsl.w   #3,d0
    move.l  (a0,d0.w),sp        ; ⑤ SPを差し替える ＝ 世界の切り替え

    movem.l (sp)+,d0-d7/a0-a6   ; ⑥ 切り替わった先の世界を復元
    rte                         ; ⑦ 「向こうの世界」の続きへ帰る

; =================================================
; SelectNext ── 次のタスクを選ぶ（ラウンドロビン）
;   入力： d1 = いまのタスク番号
;   出力： d0 = 次のタスク番号
; =================================================
SelectNext:
    movem.l d1-d3/a0,-(sp)

    lea     TaskTable,a0
    move.w  d1,d0
    moveq   #NUM_TASKS-1,d3     ; 最大この回数だけ探す

.next:
    addq.w  #1,d0               ; 一つ次へ
    cmp.w   #NUM_TASKS,d0
    blo.s   .nowrap
    clr.w   d0                  ; 端まで来たら、先頭へ戻る
.nowrap:
    move.w  d0,d1
    lsl.w   #3,d1
    tst.b   T_ALIVE(a0,d1.w)    ; そのタスクは、生きているか？
    bne.s   .found              ; 生きていれば、決まり
    dbra    d3,.next            ; 死んでいれば、次を当たる

    clr.w   d0                  ; 誰もいない（本構成では起きない）
.found:
    movem.l (sp)+,d1-d3/a0
    rts

; =================================================
; VBlankHandler ── 画面の反映は、OSの仕事
;   （この版では、切り替えはしない。数字を映すだけ）
; =================================================
VBlankHandler:
    movem.l d0-d1,-(sp)

    addq.w  #1,Tick             ; OSの時刻を進める
    move.w  #1,VBlankFlag

    move.w  CounterA,d0         ; タスクAのカウンタ → 5行目
    moveq   #5,d1
    bsr     ShowHex

    move.w  CounterB,d0         ; タスクBのカウンタ → 7行目
    moveq   #7,d1
    bsr     ShowHex

    movem.l (sp)+,d0-d1
    rte

; =================================================
; タスク（住人たち）
;
;   どちらも行儀がいい。一回数えたら、必ず譲る。
; =================================================
TaskA:
    addq.w  #1,CounterA         ; 自分の仕事
    bsr     WaitFrame           ; 1フレーム待つ（目で追える速さにする）
    trap    #0                  ; CPUを譲る
    bra.s   TaskA

TaskB:
    addq.w  #1,CounterB
    bsr     WaitFrame
    trap    #0
    bra.s   TaskB

; -------------------------------------------------
; WaitFrame ── 次のVBlankが来るまで待つ
;   これが無いと、カウンタは1秒で数万まで回ってしまい、
;   画面の数字が読めない。学習用の「歩調」である。
; -------------------------------------------------
WaitFrame:
    clr.w   VBlankFlag
.wait:
    tst.w   VBlankFlag
    beq.s   .wait
    rts

; =================================================
; 例外の受け皿（この版では、ただ帰るだけ）
; =================================================
ErrGeneric:
    rte

; =================================================
; 部品
; =================================================
    include "vdp.asm"
    include "font.asm"

    end     Start
