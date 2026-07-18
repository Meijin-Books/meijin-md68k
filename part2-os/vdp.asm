; =================================================
; vdp.asm ── 画面まわり（全バージョン共通）
;   MeijinOS68k が画面に数字を出すための、最小限の道具
;
;   このファイルは「結果を可視化する」ためだけにある。
;   OSの本質ではないので、読み飛ばしてもかまわない。
; =================================================

; --- VDPのポート ---
VDP_DATA    equ     $C00000         ; データポート
VDP_CTRL    equ     $C00004         ; コントロールポート

; --- VRAMの配置 ---
VRAM_FONT   equ     $0000           ; タイルデータの置き場（タイル0〜16）
VRAM_NAME   equ     $C000           ; ネームテーブル（画面の升目）

; 画面は 64桁 × 32行 で管理される（1マス2バイト）
NAME_W      equ     64

; =================================================
; InitVDP ── VDPを初期化して、フォントを転送する
; =================================================
InitVDP:
    movem.l d0/a0-a1,-(sp)

    ; --- VDPレジスタ24本を、まとめて設定する ---
    lea     VDP_CTRL,a0
    lea     VDPRegs,a1
    moveq   #24-1,d0
.reg:
    move.w  (a1)+,(a0)
    dbra    d0,.reg

    bsr     LoadFont            ; フォントをVRAMへ
    bsr     LoadPalette         ; 色を決める
    bsr     ClearScreen         ; 画面を空白で埋める

    movem.l (sp)+,d0/a0-a1
    rts

; =================================================
; LoadFont ── フォントのタイルを VRAM $0000 へ転送
;   1タイル32バイト × 17タイル = 544バイト
; =================================================
LoadFont:
    movem.l d0/a0-a1,-(sp)

    ; VRAM $0000 への書き込みを申告する
    lea     VDP_CTRL,a1
    move.l  #$40000000,(a1)     ; VRAM書き込み、番地$0000

    lea     FontTiles,a0
    lea     VDP_DATA,a1
    move.w  #(FontTilesEnd-FontTiles)/4-1,d0
.copy:
    move.l  (a0)+,(a1)          ; 4バイトずつ流し込む
    dbra    d0,.copy

    movem.l (sp)+,d0/a0-a1
    rts

; =================================================
; LoadPalette ── パレット0を設定する
;   色0 = 黒（背景）、色1 = 白（文字）
; =================================================
LoadPalette:
    movem.l d0/a1,-(sp)

    lea     VDP_CTRL,a1
    move.l  #$C0000000,(a1)     ; CRAM書き込み、番地$0000

    lea     VDP_DATA,a1
    move.w  #$0000,(a1)         ; 色0 = 黒
    move.w  #$0EEE,(a1)         ; 色1 = 白
    moveq   #14-1,d0
.rest:
    move.w  #$0000,(a1)         ; 残りは使わない
    dbra    d0,.rest

    movem.l (sp)+,d0/a1
    rts

; =================================================
; ClearScreen ── 画面全体を空白タイルで埋める
; =================================================
ClearScreen:
    movem.l d0/a1,-(sp)

    lea     VDP_CTRL,a1
    move.l  #$40000003,(a1)     ; VRAM書き込み、番地$C000

    lea     VDP_DATA,a1
    move.w  #64*32-1,d0
.fill:
    move.w  #TILE_BLANK,(a1)    ; 空白タイル
    dbra    d0,.fill

    movem.l (sp)+,d0/a1
    rts

; =================================================
; SetVramAddr ── VRAMへの書き込み先を申告する
;   d1 = VRAMの番地
;   （32ビットのコントロールワードを組み立てる）
; =================================================
SetVramAddr:
    movem.l d1-d3,-(sp)         ; d0は呼び出し側の値なので、壊さない

    move.l  #$40000000,d2       ; VRAM書き込みのCDコード
    move.l  d1,d3
    and.l   #$3FFF,d3           ; 番地の下位14ビット
    swap    d3
    or.l    d3,d2               ; → コントロールワードの上位へ
    move.l  d1,d3
    lsr.l   #7,d3
    lsr.l   #7,d3               ; 番地の上位2ビット（bit14-15）
    and.l   #3,d3
    or.l    d3,d2

    move.l  d2,VDP_CTRL

    movem.l (sp)+,d1-d3
    rts

; =================================================
; ShowHex ── 16進4桁で、画面に値を表示する
;   d0 = 表示する値（ワード）
;   d1 = 行番号（0〜27）
;
;   画面の左から8桁めの位置に、4桁ぶん描く
; =================================================
ShowHex:
    movem.l d0-d3/a1,-(sp)

    move.w  d0,d3               ; d3 = 表示する値（退避）

    ; --- 書き込み先のVRAM番地を計算する ---
    ;     $C000 + 行 × 64マス × 2バイト + 8桁 × 2バイト
    and.l   #$FFFF,d1
    lsl.l   #7,d1               ; 行 × 128（= 64マス × 2バイト）
    add.l   #VRAM_NAME+16,d1    ; + 左から8桁ぶん
    bsr     SetVramAddr

    ; --- 上位の桁から順に、4桁ぶん出す ---
    lea     VDP_DATA,a1
    moveq   #4-1,d2
.digit:
    rol.w   #4,d3               ; 最上位4ビットを、下位へ回す
    move.w  d3,d0
    and.w   #$000F,d0           ; その4ビットだけ取り出す
    move.w  d0,(a1)             ; タイル番号 = 数字の値（0〜F）
    dbra    d2,.digit

    movem.l (sp)+,d0-d3/a1
    rts

; =================================================
; ShowByte ── 16進2桁で、画面に値を表示する
;   d0 = 表示する値（バイト）
;   d1 = 行番号
; =================================================
ShowByte:
    movem.l d0-d3/a1,-(sp)

    move.w  d0,d3
    lsl.w   #8,d3               ; 上位バイトへ寄せる

    and.l   #$FFFF,d1
    lsl.l   #7,d1
    add.l   #VRAM_NAME+16,d1
    bsr     SetVramAddr

    lea     VDP_DATA,a1
    moveq   #2-1,d2
.digit:
    rol.w   #4,d3
    move.w  d3,d0
    and.w   #$000F,d0
    move.w  d0,(a1)
    dbra    d2,.digit

    movem.l (sp)+,d0-d3/a1
    rts

; =================================================
; VDPレジスタ24本の設定値
;   $8x = レジスタ番号x への書き込み
; =================================================
VDPRegs:
    dc.w    $8004               ; 0: HBlank割り込み禁止
    dc.w    $8174               ; 1: 画面ON、VBlank割り込み許可 ← bit5
    dc.w    $8230               ; 2: スクロールA ネームテーブル = $C000
    dc.w    $8300               ; 3: ウィンドウ = $0000
    dc.w    $8407               ; 4: スクロールB ネームテーブル = $E000
    dc.w    $8500               ; 5: スプライトテーブル = $0000
    dc.w    $8600               ; 6: 未使用
    dc.w    $8700               ; 7: 背景色 = パレット0の色0
    dc.w    $8800               ; 8: 未使用
    dc.w    $8900               ; 9: 未使用
    dc.w    $8A00               ; 10: HBlankカウンタ
    dc.w    $8B00               ; 11: スクロールモード
    dc.w    $8C81               ; 12: 40桁モード
    dc.w    $8D3C               ; 13: 水平スクロールテーブル = $F000
    dc.w    $8E00               ; 14: 未使用
    dc.w    $8F02               ; 15: オートインクリメント = 2バイト
    dc.w    $9001               ; 16: スクロールサイズ 64x32
    dc.w    $9100               ; 17: ウィンドウ水平位置
    dc.w    $9200               ; 18: ウィンドウ垂直位置
    dc.w    $9300               ; 19: DMA長 下位
    dc.w    $9400               ; 20: DMA長 上位
    dc.w    $9500               ; 21: DMA元 下位
    dc.w    $9600               ; 22: DMA元 中位
    dc.w    $9700               ; 23: DMA元 上位
