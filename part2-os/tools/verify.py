#!/usr/bin/env python3
# =====================================================================
# verify.py ── 本書（第二部）の主張を、実際に走らせて確かめる
#
#   emu68k.py（小さな68000エミュレータ）で各プログラムを実行し、
#   本文の主張（2A=2A／プリエンプション／特権違反／トレース／隣人破壊
#   など）が本当に成り立つかを機械的に検査します。
#
#   使い方：  python3 tools/verify.py      （part2-os/ で実行）
#            または  make verify
# =====================================================================
import os, sys, re
HERE=os.path.dirname(os.path.abspath(__file__))
OS=os.path.dirname(HERE)                      # part2-os/
sys.path.insert(0,HERE)
import emu68k

def asm(name): return os.path.join(OS,name)
def run(name, **kw):
    mac,meta=emu68k.run_program([asm(name)], **kw)
    return mac,meta

def alive(m,ntask=3,T=12,base=0xFF0020):
    return [m.read8(base+i*T+4) for i in range(ntask)]

# ---- 静的解析 ----
def count_yield_instrs(meta):
    syms,instrs,prog=meta
    ya=syms.get('Yield')
    seq=[i for i in instrs if i.addr>=ya]
    seq.sort(key=lambda i:i.addr)
    n=0
    for ins in seq:
        n+=1
        if ins.mnem=='rte': break
    return n

def src(name): return open(asm(name),encoding='utf-8').read()

RESULTS=[]
def check(no, chapter, title, ok, detail):
    RESULTS.append((no,chapter,title,ok,detail))

# =====================================================================
# 検査
# =====================================================================
def main():
    # [1] ベクタ表：trap #0 の飛び先は SysYield（ベクタ32番＝$080）
    m,meta=run('coop.asm', max_steps=1, vblank=False)
    v32=m.read32(32*4); sysy=meta[0].get('SysYield')
    check(1,'第16章','trap #0 はベクタ32番へ（システムコールの玄関）', v32==sysy, f'vec32=${v32:06X} == SysYield=${sysy:06X}')

    # [2] 心臓部は13命令
    n=count_yield_instrs(meta)
    check(2,'第16章','Yield は13命令（心臓部）', n==13, f'実測 {n} 命令')

    # [3] 偽の履歴は66バイト（15本×4 + SR2 + PC4）
    ok='suba.l  #66' in src('coop.asm')
    check(3,'第16章','偽の履歴は66バイト（InitTask）', ok, 'suba.l #66,a1 を確認')

    # [4] coop：全員スーパーバイザで生まれる（偽SR=$2000）
    ok='#$2000,(a0)+' in src('coop.asm')
    check(4,'第17章','協調版のタスクは S=1（偽SR=$2000）', ok, '偽SR=$2000 を確認')

    # [5] meijin10：ユーザモードで生まれる（偽SR=$0000）
    ok='#$0000,(a0)+' in src('meijin10.asm')
    check(5,'第18章','完成版のタスクは S=0（偽SR=$0000）', ok, '偽SR=$0000 を確認')

    # [6] coop：2A = 2A（別タスクが同じ値まで進む）
    m,_=run('coop.asm', max_steps=600000, frame_steps=2000)
    a=m.read16(0xFF0004); b=m.read16(0xFF0006)
    check(6,'第17章','協調的マルチタスク（2A = 2A）', a>0 and abs(a-b)<=1, f'A={a} B={b}（差={abs(a-b)}）')

    # [7] preempt：誰も譲らないのに両方動く（プリエンプション）
    m,_=run('preempt.asm', max_steps=600000, frame_steps=2000)
    a=m.read16(0xFF0004); b=m.read16(0xFF0006)
    check(7,'第19章','プリエンプティブ（誰も譲らないのに両方動く）', a>0 and b>0, f'A={a} B={b}')

    # [8] meijin10：3タスクが同居し、全員生きている
    m,_=run('meijin10.asm', max_steps=600000, frame_steps=2000)
    al=alive(m); tick=m.read16(0xFF0000)
    check(8,'第27章','3タスク同居・全員生存（時計＋カウンタ＋ゾンビ）', tick>0 and al==[1,1,1], f'Tick={tick} alive={al}')

    # [9] meijin10：ゾンビが暴れても時刻は進む（プリエンプションが効く）
    check(9,'第19章','ゾンビが暴れても Tick が進む', tick>0, f'Tick={tick}')

    # [10] 特権違反：ユーザモードで特権命令を使ったタスクだけが死ぬ
    s=src('meijin10.asm').replace(
        "TaskZombie:\n    moveq   #0,d2\n.loop:\n    addq.w  #1,d2",
        "TaskZombie:\n    moveq   #0,d2\n.loop:\n    move.w  #$2700,sr\n    addq.w  #1,d2")
    tmp=asm('_verify_priv.asm'); open(tmp,'w',encoding='utf-8').write(s)
    try:
        m,_=emu68k.run_program([tmp], max_steps=300000, frame_steps=2000)
        al=alive(m); ec=m.read16(0xFF0008)
        check(10,'第23章','特権違反を捕まえる（犯人だけ死ぬ）', al==[1,1,0] and ec==0x8E, f'alive={al} ErrCode=${ec:04X}')
    finally:
        os.remove(tmp)

    # [11] トレース：Tビットで1命令ごとに例外が起き、命令数を数えられる
    m,_=run('trace.asm', max_steps=400000, frame_steps=2000)
    tc=m.read32(0xFF001C); ta=m.read32(0xFF0018)
    check(11,'第23章','トレース機構（ステップ実行の正体）', tc>0, f'TraceCount={tc} TraceAddr=${ta:06X}')

    # [12] 隣人破壊：task0 の配列あふれで、無関係な task1 が死ぬ（保護は半分）
    m,_=run('crash.asm', max_steps=600000, frame_steps=2000)
    al=alive(m); ec=m.read16(0xFF0008)
    check(12,'第26章','隣人を殺す（保護は半分しかない）', al[1]==0, f'alive={al} ErrCode=${ec:04X}')

    # ---- レポート ----
    print("="*64)
    print(" MeijinOS68k ── 本書の主張を、実際に走らせて検査")
    print("="*64)
    ok_n=0
    for no,ch,title,ok,detail in RESULTS:
        mark='OK  ' if ok else 'FAIL'
        print(f"[{no:2}] {ch}：{title}")
        print(f"     [{mark}] {detail}")
        ok_n+=1 if ok else 0
    print("-"*64)
    print(f"結果： {ok_n} / {len(RESULTS)} 項目が OK")
    return 0 if ok_n==len(RESULTS) else 1

if __name__=='__main__':
    sys.exit(main())
