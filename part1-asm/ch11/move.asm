;=====================================================
; 第11章　動くものを作る
; 十字キーでスプライトが動く（完成版）
;=====================================================

VDP_DATA    equ $C00000
VDP_CTRL    equ $C00004

PAD1_DATA   equ $A10003
PAD1_CTRL   equ $A10009

STACK_TOP   equ $FFFFFE

; --- 変数 ---
wPadNow     equ $FF0000     ; 今回の入力
wPadOld     equ $FF0002     ; 前回の入力
wPadEdge    equ $FF0004     ; 押した瞬間
wPlayerX    equ $FF0006     ; プレイヤーX座標
wPlayerY    equ $FF0008     ; プレイヤーY座標
wVBlankFlag equ $FF000A     ; VBlank到来フラグ

; --- ボタンのビット番号 ---
BTN_UP      equ 0
BTN_DOWN    equ 1
BTN_LEFT    equ 2
BTN_RIGHT   equ 3
BTN_B       equ 4
BTN_C       equ 5
BTN_A       equ 12
BTN_START   equ 13

; --- スプライトテーブルの位置（VDPレジスタ5 = $6C）---
SPRITE_ADDR equ $D800

;-----------------------------------------------------
; ベクタテーブル
;-----------------------------------------------------
    org     $000000
    dc.l    STACK_TOP           ; vec0: 初期SP
    dc.l    EntryPoint          ; vec1: 初期PC
    dcb.l   26, Exception       ; vec2〜27
    dc.l    Exception           ; vec28: レベル4 = HBlank
    dc.l    Exception           ; vec29: レベル5
    dc.l    VBlankHandler       ; vec30: レベル6 = VBlank
    dcb.l   33, Exception       ; vec31〜63

;-----------------------------------------------------
; ROMヘッダ
;-----------------------------------------------------
    org     $000100
    dc.b    "SEGA MEGA DRIVE "
    dc.b    "(C)MEIJIN 2026  "
    dc.b    "MOVING SPRITE                                   "
    dc.b    "MOVING SPRITE                                   "
    dc.b    "GM 00000000-00"
    dc.w    $0000
    dc.b    "J               "
    dc.l    $00000000, $000FFFFF
    dc.l    $00FF0000, $00FFFFFF
    dc.b    "            "
    dc.b    "                                        "
    dc.b    "JUE             "

;-----------------------------------------------------
; 本体
;-----------------------------------------------------
    org     $000200

EntryPoint:
    move.w  #$2700,sr           ; 割り込みを全部止める

    ; --- VDPレジスタの初期化 ---
    lea     VDP_CTRL,a0
    lea     VDPRegs,a1
    move.w  #$8000,d0
    moveq   #23,d1
.initVDP:
    move.b  (a1)+,d0
    move.w  d0,(a0)
    add.w   #$0100,d0
    dbra    d1,.initVDP

    ; --- パッドの初期化 ---
    move.b  #$40,PAD1_CTRL      ; bit6(TH)を出力に

    ; --- 変数の初期化 ---
    clr.w   wPadNow
    clr.w   wPadOld
    clr.w   wPadEdge
    clr.w   wVBlankFlag
    move.w  #152,wPlayerX       ; 画面中央あたり
    move.w  #108,wPlayerY

    ; --- パレットを CRAM へ ---
    move.l  #$C0000000,VDP_CTRL
    lea     Palette,a1
    moveq   #15,d1
.copyPal:
    move.w  (a1)+,VDP_DATA
    dbra    d1,.copyPal

    ; --- タイルを VRAM へ ---
    move.l  #$40000000,VDP_CTRL
    lea     Tiles,a1
    move.w  #(TilesEnd-Tiles)/2-1,d1
.copyTiles:
    move.w  (a1)+,VDP_DATA
    dbra    d1,.copyTiles

    ; --- スプライトテーブルを掃除する ---
    ; 電源投入直後はゴミ。80体 x 8バイト = 640バイト
    move.l  #$58000003,VDP_CTRL ; VRAM $D800 へ
    move.w  #(640/2)-1,d1
    moveq   #0,d0
.clearSprites:
    move.w  d0,VDP_DATA
    dbra    d1,.clearSprites

    ; --- 画面を点ける + VBlank割り込みを許可 ---
    move.w  #$8164,VDP_CTRL     ; レジスタ1: 表示ON + VBlank割込ON
    move.w  #$2500,sr           ; マスク5 → レベル6を通す

;-----------------------------------------------------
; メインループ
;-----------------------------------------------------
Main:
    jsr     ReadPad             ; 入力を読む
    jsr     MovePlayer          ; 座標を更新

    ; VBlankを待つ
    clr.w   wVBlankFlag
.wait:
    tst.w   wVBlankFlag
    beq     .wait

    bra     Main

;-----------------------------------------------------
; パッドを読む
;-----------------------------------------------------
ReadPad:
    move.w  wPadNow,wPadOld     ; 今回の値を「前回」へ

    move.b  #$00,PAD1_DATA      ; TH=0
    nop
    nop
    move.b  PAD1_DATA,d0        ; ?0SA00DU
    rol.w   #8,d0               ; 上位バイトへ

    move.b  #$40,PAD1_DATA      ; TH=1
    nop
    nop
    move.b  PAD1_DATA,d0        ; ?1CBRLDU

    not.w   d0                  ; 押した=1 に反転
    move.w  d0,wPadNow

    move.w  wPadOld,d1          ; エッジ検出
    not.w   d1
    and.w   d0,d1
    move.w  d1,wPadEdge
    rts

;-----------------------------------------------------
; 入力で座標を動かす
;-----------------------------------------------------
MovePlayer:
    move.w  wPadNow,d0

    moveq   #1,d2               ; 通常の速さ
    btst    #BTN_A,d0           ; Aを押していれば
    beq     .normalSpeed
    moveq   #4,d2               ; 4倍速
.normalSpeed:

    btst    #BTN_RIGHT,d0
    beq     .notRight
    add.w   d2,wPlayerX
.notRight:

    btst    #BTN_LEFT,d0
    beq     .notLeft
    sub.w   d2,wPlayerX
.notLeft:

    btst    #BTN_DOWN,d0
    beq     .notDown
    add.w   d2,wPlayerY
.notDown:

    btst    #BTN_UP,d0
    beq     .notUp
    sub.w   d2,wPlayerY
.notUp:
    rts

;-----------------------------------------------------
; VBlank割り込みハンドラ
;-----------------------------------------------------
VBlankHandler:
    movem.l d0-d1/a0,-(sp)

    ; スプライトテーブルの0番へ書く
    move.l  #$58000003,VDP_CTRL ; VRAM $D800
    lea     VDP_DATA,a0

    move.w  wPlayerY,d0
    add.w   #128,d0             ; 原点補正
    move.w  d0,(a0)             ; +0: Y座標

    move.w  #$0F00,(a0)         ; +2: リンク0 / サイズ32x32

    move.w  #$0001,(a0)         ; +4: パレット0, タイル1番から

    move.w  wPlayerX,d0
    add.w   #128,d0             ; 原点補正
    move.w  d0,(a0)             ; +6: X座標

    move.w  #1,wVBlankFlag      ; 「来たよ」と伝える

    movem.l (sp)+,d0-d1/a0
    rte

Exception:
    rte

;-----------------------------------------------------
; データ
;-----------------------------------------------------
VDPRegs:
    dc.b    $04     ; 00: HBlank割り込み禁止
    dc.b    $04     ; 01: 表示OFF・VBlank割込OFF（後で点ける）
    dc.b    $30     ; 02: スクロールA = $C000
    dc.b    $3C     ; 03: ウィンドウ = $F000
    dc.b    $07     ; 04: スクロールB = $E000
    dc.b    $6C     ; 05: スプライトテーブル = $D800
    dc.b    $00     ; 06: 未使用
    dc.b    $00     ; 07: 背景色 = パレット0の色0
    dc.b    $00     ; 08: 未使用
    dc.b    $00     ; 09: 未使用
    dc.b    $FF     ; 10: HBlank間隔
    dc.b    $00     ; 11: スクロール方式
    dc.b    $81     ; 12: 40桁モード
    dc.b    $37     ; 13: 水平スクロールテーブル = $DC00
    dc.b    $00     ; 14: 未使用
    dc.b    $02     ; 15: オートインクリメント = 2
    dc.b    $01     ; 16: スクロールサイズ 64x32
    dc.b    $00     ; 17: ウィンドウ水平位置
    dc.b    $00     ; 18: ウィンドウ垂直位置
    dc.b    $FF     ; 19: DMA長さ 下位
    dc.b    $FF     ; 20: DMA長さ 上位
    dc.b    $00     ; 21: DMA元 下位
    dc.b    $00     ; 22: DMA元 中位
    dc.b    $80     ; 23: DMA元 上位
    even

Palette:
    dc.w    $0000   ; 0: 透明
    dc.w    $0EEE   ; 1: 白
    dc.w    $000E   ; 2: 赤
    dc.w    $0E00   ; 3: 青
    dc.w    $00E0   ; 4: 緑
    dc.w    $008E   ; 5: 橙
    dc.w    $0EE0   ; 6: 水色
    dc.w    $0666   ; 7: 灰
    dc.w    $0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000

Tiles:
    ; タイル0: 空白
    dcb.l   8,$00000000

    ; タイル1〜16: 32x32のキャラクター（4x4タイル）
    ; ★重要: 縦に並べてから、横へ進む
    ;  列0: タイル1,2,3,4   列1: タイル5,6,7,8
    ;  列2: タイル9,10,11,12  列3: タイル13,14,15,16

    ; --- 列0 上 (タイル1) ---
    dc.l    $00000000
    dc.l    $00000000
    dc.l    $00000111
    dc.l    $00011111
    dc.l    $00111111
    dc.l    $01111111
    dc.l    $01111111
    dc.l    $11111111
    ; --- 列0 中上 (タイル2) ---
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111122
    dc.l    $11111222
    dc.l    $11112222
    dc.l    $11122222
    dc.l    $11122222
    dc.l    $11222222
    ; --- 列0 中下 (タイル3) ---
    dc.l    $11222222
    dc.l    $11122222
    dc.l    $11122222
    dc.l    $11112222
    dc.l    $11111222
    dc.l    $11111122
    dc.l    $11111111
    dc.l    $11111111
    ; --- 列0 下 (タイル4) ---
    dc.l    $11111111
    dc.l    $01111111
    dc.l    $01111111
    dc.l    $00111111
    dc.l    $00011111
    dc.l    $00000111
    dc.l    $00000000
    dc.l    $00000000

    ; --- 列1 上 (タイル5) ---
    dc.l    $00000000
    dc.l    $01111000
    dc.l    $11111110
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    ; --- 列1 中上 (タイル6) ---
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    ; --- 列1 中下 (タイル7) ---
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $11111111
    dc.l    $11111111
    ; --- 列1 下 (タイル8) ---
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111110
    dc.l    $01111000
    dc.l    $00000000

    ; --- 列2 上 (タイル9) ---
    dc.l    $00000000
    dc.l    $00011110
    dc.l    $01111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    ; --- 列2 中上 (タイル10) ---
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    ; --- 列2 中下 (タイル11) ---
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $22222222
    dc.l    $11111111
    dc.l    $11111111
    ; --- 列2 下 (タイル12) ---
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $01111111
    dc.l    $00011110
    dc.l    $00000000

    ; --- 列3 上 (タイル13) ---
    dc.l    $00000000
    dc.l    $00000000
    dc.l    $11100000
    dc.l    $11111000
    dc.l    $11111100
    dc.l    $11111110
    dc.l    $11111110
    dc.l    $11111111
    ; --- 列3 中上 (タイル14) ---
    dc.l    $11111111
    dc.l    $11111111
    dc.l    $22111111
    dc.l    $22211111
    dc.l    $22221111
    dc.l    $22222111
    dc.l    $22222111
    dc.l    $22222211
    ; --- 列3 中下 (タイル15) ---
    dc.l    $22222211
    dc.l    $22222111
    dc.l    $22222111
    dc.l    $22221111
    dc.l    $22211111
    dc.l    $22111111
    dc.l    $11111111
    dc.l    $11111111
    ; --- 列3 下 (タイル16) ---
    dc.l    $11111111
    dc.l    $11111110
    dc.l    $11111110
    dc.l    $11111100
    dc.l    $11111000
    dc.l    $11100000
    dc.l    $00000000
    dc.l    $00000000
TilesEnd:

    end
