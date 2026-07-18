#!/usr/bin/env python3
# =====================================================================
# emu68k.py ── MeijinOS68k 検証用の、小さな68000アセンブラ＋エミュレータ
#   本書（第二部）のコードが使う命令だけを実装した教材専用の実装。
#   BlastEm の代わりにはならないが、タスク切替・特権違反・トレース・
#   隣人破壊 を機械的に確認するには十分。verify.py から呼ばれる。
# =====================================================================
import re, os

class Emu68kError(Exception): pass
class AddressError(Exception):
    def __init__(self,addr): self.addr=addr

M32=0xFFFFFFFF
def s32(v): v&=M32; return v-0x100000000 if v&0x80000000 else v
def s16(v): v&=0xFFFF; return v-0x10000 if v&0x8000 else v
def s8(v):  v&=0xFF;   return v-0x100 if v&0x80 else v
SZMASK={'b':0xFF,'w':0xFFFF,'l':M32}
SZBYTES={'b':1,'w':2,'l':4}
SZSIGN={'b':s8,'w':s16,'l':s32}

# ---------------------------------------------------------------------
# expression evaluation
# ---------------------------------------------------------------------
def _prep(e):
    def chrepl(m):
        v=0
        for c in m.group(1): v=(v<<8)|ord(c)
        return str(v)
    e=re.sub(r"'([^']*)'",chrepl,e)
    e=re.sub(r'\$([0-9A-Fa-f]+)',r'0x\1',e)
    return e
def eval_expr(e,syms):
    e=_prep(e).strip()
    if not e: return 0
    def idrepl(m):
        n=m.group(0)
        if n[:2].lower()=='0x': return n       # hex literal, leave as-is
        if n in syms: return '('+str(syms[n])+')'
        raise Emu68kError("undefined symbol %r"%n)
    tok=re.sub(r'0[xX][0-9A-Fa-f]+|[A-Za-z_.][A-Za-z0-9_.]*',idrepl,e)
    try: return int(eval(tok,{"__builtins__":{}},{}))
    except Emu68kError: raise
    except Exception as ex: raise Emu68kError("bad expr %r (%s)"%(e,ex))

# ---------------------------------------------------------------------
# assembler
# ---------------------------------------------------------------------
class Instr:
    __slots__=('addr','mnem','size','ops','text','nxt')
    def __init__(s,addr,mnem,size,ops,text):
        s.addr=addr; s.mnem=mnem; s.size=size; s.ops=ops; s.text=text; s.nxt=0

def _split(s):
    out=[]; d=0; cur=''
    for ch in s:
        if ch=='(':d+=1;cur+=ch
        elif ch==')':d-=1;cur+=ch
        elif ch==','and d==0:out.append(cur.strip());cur=''
        else:cur+=ch
    if cur.strip():out.append(cur.strip())
    return out

def _isize(ops):
    n=2
    for o in ops:
        if o.startswith('#'):n+=4
        elif '(' in o and not o.startswith('-('):n+=2
        elif re.fullmatch(r'-?[$]?[0-9A-Fa-f]+',o):n+=4
        elif re.match(r'^[A-Za-z_]',o) and '(' not in o and o.lower() not in('sr','usp','ccr','sp') and not re.fullmatch(r'[ad][0-7]',o):n+=4
    return n

def load_source(files):
    lines=[]
    def load(path):
        with open(path,encoding='utf-8') as f:
            for ln in f:
                m=re.match(r'\s*include\s+"([^"]+)"',ln)
                if m: load(os.path.join(os.path.dirname(path),m.group(1)))
                else: lines.append(ln.rstrip('\n'))
    for fp in files: load(fp)
    return lines

def assemble(files):
    raw=load_source(files)
    syms={}; instrs=[]; mem={}
    for pass_no in (1,2):
        lc=0; cur_global=None
        for line in raw:
            code=line.split(';',1)[0].rstrip()
            if not code.strip(): continue
            if code[0] not in ' \t':
                m=re.match(r'([.\w]+):?\s*(.*)',code)
                label=m.group(1); rest=m.group(2).strip()
            else:
                label=None; rest=code.strip()
            if label is not None and not label.startswith('.'): cur_global=label
            flabel=None
            if label is not None:
                flabel=(cur_global or '')+label if label.startswith('.') else label
            parts=rest.split(None,1); op=parts[0].lower() if parts else ''; arg=parts[1].strip() if len(parts)>1 else ''
            if op=='equ':
                if pass_no==1: syms[label]=eval_expr(arg,syms)
                continue
            if op=='org':
                lc=eval_expr(arg,syms)
                if label is not None and pass_no==1: syms[flabel]=lc
                continue
            if label is not None and pass_no==1 and flabel not in syms: syms[flabel]=lc
            if op=='' or op=='end': continue
            if op=='even':
                if lc&1:
                    if pass_no==2: mem[lc]=0
                    lc+=1
                continue
            if op.startswith('dc.') and op[3] in 'bwl':
                sz=SZBYTES[op[3]]
                for it in _split(arg):
                    if it.startswith('"') and it.endswith('"'):
                        s=it[1:-1]
                        if pass_no==2:
                            for i,c in enumerate(s): mem[lc+i]=ord(c)&0xFF
                        lc+=len(s)
                    else:
                        if pass_no==2:
                            v=eval_expr(it,syms)
                            for k in range(sz): mem[lc+k]=(v>>(8*(sz-1-k)))&0xFF
                        lc+=sz
                continue
            if op.startswith('dcb.') and op[4] in 'bwl':
                sz=SZBYTES[op[4]]; a=_split(arg); cnt=eval_expr(a[0],syms)
                val=(eval_expr(a[1],syms) if len(a)>1 else 0) if pass_no==2 else 0
                for _ in range(cnt):
                    if pass_no==2:
                        for k in range(sz): mem[lc+k]=(val>>(8*(sz-1-k)))&0xFF
                    lc+=sz
                continue
            if op.startswith('ds.') and op[3] in 'bwl':
                lc+=SZBYTES[op[3]]*eval_expr(arg,syms); continue
            # instruction
            base=op; sz='w'
            if '.' in op: base,sz=op.split('.',1)
            ops=_split(arg) if arg else []
            if pass_no==2:
                qops=[( (cur_global or '')+o if o.startswith('.') else o) for o in ops]
                instrs.append(Instr(lc,base,sz,qops,line.strip()))
            lc+=_isize(ops)
    # link next-addresses
    for i,ins in enumerate(instrs):
        ins.nxt=instrs[i+1].addr if i+1<len(instrs) else ins.addr
    prog={ins.addr:ins for ins in instrs}
    return syms,instrs,prog,mem

# ---------------------------------------------------------------------
# machine
# ---------------------------------------------------------------------
class Machine:
    def __init__(self,syms,instrs,prog,mem):
        self.syms=syms; self.instrs=instrs; self.prog=prog
        self.rom=dict(mem)                 # assembled bytes (vectors/header/data)
        self.ram=bytearray(0x10000)        # $FF0000..$FFFFFF
        self.D=[0]*8; self.A=[0]*8
        self.usp=0; self.ssp=0
        self.pc=0; self.sr=0x2700
        self.halted=False; self.steps=0
        self.pad_value=0xFF                # active-low idle
        self._opcache={}
        # reset
        self.ssp=self.read32(0); self.A[7]=self.ssp
        self.pc=self.read32(4); self.sr=0x2700
    # ---- SR helpers ----
    @property
    def S(self): return (self.sr>>13)&1
    @property
    def T(self): return (self.sr>>15)&1
    @property
    def mask(self): return (self.sr>>8)&7
    def set_ccr(self,X=None,N=None,Z=None,V=None,C=None):
        for bit,val in ((4,X),(3,N),(2,Z),(1,V),(0,C)):
            if val is not None:
                if val: self.sr|=(1<<bit)
                else: self.sr&=~(1<<bit)
    def getC(self):return (self.sr>>0)&1
    # ---- memory ----
    def _io_read(self,addr,size):
        if 0xA10003<=addr<=0xA10005: return self.pad_value
        if 0xC00000<=addr<=0xC00007: return 0      # VDP status
        return 0
    def _io_write(self,addr,size,val): pass         # VDP/pad/Z80 writes: ignore
    def read8(self,addr):
        addr&=M32
        if 0xFF0000<=addr<=0xFFFFFF: return self.ram[addr-0xFF0000]
        if addr>=0xA00000: return self._io_read(addr,1)&0xFF
        return self.rom.get(addr,0)
    def write8(self,addr,val):
        addr&=M32; val&=0xFF
        if 0xFF0000<=addr<=0xFFFFFF: self.ram[addr-0xFF0000]=val; return
        if addr>=0xA00000: self._io_write(addr,1,val); return
        self.rom[addr]=val   # ROM writes silently ignored on real HW; keep for tools
    def read16(self,addr):
        if addr&1: raise AddressError(addr)
        if 0xA00000<=addr<0xFF0000: return self._io_read(addr,2)&0xFFFF
        return (self.read8(addr)<<8)|self.read8(addr+1)
    def read32(self,addr):
        if addr&1: raise AddressError(addr)
        return (self.read16(addr)<<16)|self.read16(addr+2)
    def write16(self,addr,val):
        if addr&1: raise AddressError(addr)
        if 0xA00000<=addr<0xFF0000: self._io_write(addr,2,val); return
        self.write8(addr,(val>>8)&0xFF); self.write8(addr+1,val&0xFF)
    def write32(self,addr,val):
        if addr&1: raise AddressError(addr)
        self.write16(addr,(val>>16)&0xFFFF); self.write16(addr+2,val&0xFFFF)
    def read(self,addr,sz): return {'b':self.read8,'w':self.read16,'l':self.read32}[sz](addr)
    def write(self,addr,sz,v): {'b':self.write8,'w':self.write16,'l':self.write32}[sz](addr,v&SZMASK[sz])
    # ---- mode ----
    def enter_super(self):
        if self.S==0:
            self.usp=self.A[7]; self.A[7]=self.ssp; self.sr|=(1<<13)
    def restore_sr(self,newsr):
        news=(newsr>>13)&1
        if news==0 and self.S==1:
            self.ssp=self.A[7]; self.A[7]=self.usp
        elif news==1 and self.S==0:
            self.usp=self.A[7]; self.A[7]=self.ssp
        self.sr=newsr&0xFFFF
    # ---- exceptions ----
    def push16(self,v): self.A[7]=(self.A[7]-2)&M32; self.write16(self.A[7],v&0xFFFF)
    def push32(self,v): self.A[7]=(self.A[7]-4)&M32; self.write32(self.A[7],v&M32)
    def exception(self,vec,ret_pc,group0=False,set_mask=None):
        old=self.sr
        self.enter_super()
        self.sr&=~(1<<15)   # clear T
        if set_mask is not None: self.sr=(self.sr&~0x700)|((set_mask&7)<<8)
        if group0:
            self.A[7]=(self.A[7]-14)&M32
            self.write16(self.A[7]+8,old&0xFFFF)
            self.write32(self.A[7]+10,ret_pc&M32)
        else:
            self.push32(ret_pc); self.push16(old)
        self.pc=self.read32(vec*4)
    # ---- operand parsing ----
    def parse_op(self,o):
        key=o
        c=self._opcache.get(key)
        if c is not None: return c
        r=self._parse_op(o); self._opcache[key]=r; return r
    def _parse_op(self,o):
        o=o.strip()
        lo=o.lower()
        if lo in ('sr','ccr','usp'): return (lo,)
        if re.fullmatch(r'd[0-7]',lo): return ('D',int(lo[1]))
        if re.fullmatch(r'a[0-7]',lo): return ('A',int(lo[1]))
        if lo=='sp': return ('A',7)
        if o.startswith('#'): return ('imm',eval_expr(o[1:],self.syms))
        if o.startswith('-(') and o.endswith(')'): return ('predec',self._an(o[2:-1]))
        if o.endswith(')+'):
            return ('postinc',self._an(o[o.index('(')+1:-2]))
        if o.endswith(')') and '(' in o:
            disp=o[:o.index('(')]; inside=o[o.index('(')+1:-1]
            parts=[p.strip() for p in inside.split(',')]
            base=parts[0].lower()
            d=eval_expr(disp,self.syms) if disp.strip() else 0
            if len(parts)==1:
                if base=='pc': return ('pcdisp',d)
                return ('disp',self._an(base),d) if base!='' else ('disp',0,d)
            # index
            idx=parts[1]; isz='w'
            if '.' in idx: idxr,isz=idx.split('.');
            else: idxr=idx
            rt='D' if idxr.lower().startswith('d') else 'A'
            rn=int(idxr[1])
            if base=='pc': return ('pcindex',d,rt,rn,isz)
            return ('index',self._an(base),d,rt,rn,isz)
        if re.fullmatch(r'[.\w$]+',o) or '-' in o or '+' in o:  # absolute (symbol/number/expr)
            return ('abs',eval_expr(o,self.syms))
        raise Emu68kError("cannot parse operand %r"%o)
    def _an(self,s):
        s=s.strip().lower()
        if s=='sp': return 7
        if re.fullmatch(r'a[0-7]',s): return int(s[1])
        raise Emu68kError("expected An, got %r"%s)
    # ---- effective address value read/write ----
    def ea_addr(self,op,sz):
        t=op[0]
        if t=='ind': return self.A[op[1]]&M32
        if t=='postinc':
            a=self.A[op[1]]&M32; self.A[op[1]]=(a+SZBYTES[sz])&M32; return a
        if t=='predec':
            a=(self.A[op[1]]-SZBYTES[sz])&M32; self.A[op[1]]=a; return a
        if t=='disp': return (self.A[op[1]]+op[2])&M32
        if t=='index':
            _,an,d,rt,rn,isz=op
            idx=(self.D[rn] if rt=='D' else self.A[rn])
            idx=s16(idx) if isz=='w' else s32(idx)
            return (self.A[an]+d+idx)&M32
        if t=='abs': return op[1]&M32
        if t=='pcdisp': return op[1]&M32
        raise Emu68kError("no addr for %r"%(op,))
    def src(self,op,sz):
        t=op[0]
        if t=='D': return self.D[op[1]]&SZMASK[sz]
        if t=='A': return self.A[op[1]]&SZMASK[sz] if sz!='l' else self.A[op[1]]&M32
        if t=='imm': return op[1]&SZMASK[sz]
        if t=='sr': return self.sr&0xFFFF
        if t=='usp': return self.usp&M32
        return self.read(self.ea_addr(op,sz),sz)
    def dst_write(self,op,sz,val):
        t=op[0]; val&=SZMASK[sz]
        if t=='D':
            self.D[op[1]]=(self.D[op[1]]&~SZMASK[sz]&M32)|val; return
        if t=='A':
            self.A[op[1]]=SZSIGN[sz](val)&M32 if sz!='l' else val&M32; return
        if t=='sr':
            self.restore_sr(val); return
        if t=='usp':
            self.usp=val&M32; return
        self.write(self.ea_addr(op,sz),sz,val)
    # ---- flags for logic/move ----
    def set_nz(self,val,sz,clearVC=True):
        m=SZMASK[sz]; val&=m
        self.set_ccr(N=1 if val&((m+1)>>1) else 0, Z=1 if val==0 else 0)
        if clearVC: self.set_ccr(V=0,C=0)
    def set_add(self,a,b,r,sz):
        m=SZMASK[sz]; sb=(m+1)>>1
        rr=r&m
        C=1 if (r>>SZBYTES[sz]*8)&1 or r>m else 0
        C=1 if (a&m)+(b&m)>m else 0
        N=1 if rr&sb else 0; Z=1 if rr==0 else 0
        V=1 if (((a&sb)==(b&sb)) and ((rr&sb)!=(a&sb))) else 0
        self.set_ccr(X=C,N=N,Z=Z,V=V,C=C)
    def set_sub(self,a,b,sz):  # a-b (dest-src)
        m=SZMASK[sz]; sb=(m+1)>>1
        r=(a-b)&m
        C=1 if (a&m)<(b&m) else 0
        N=1 if r&sb else 0; Z=1 if r==0 else 0
        V=1 if (((a&sb)!=(b&sb)) and ((r&sb)!=(a&sb))) else 0
        self.set_ccr(X=C,N=N,Z=Z,V=V,C=C)
        return r
    # ---- condition ----
    def cond(self,cc):
        sr=self.sr; C=sr&1; V=(sr>>1)&1; Z=(sr>>2)&1; N=(sr>>3)&1
        cc=cc.lower()
        return {
          't':1,'f':0,'ra':1,
          'eq':Z,'ne':1-Z,'cs':C,'lo':C,'cc':1-C,'hs':1-C,
          'mi':N,'pl':1-N,'vs':V,'vc':1-V,
          'hi':1 if (not C and not Z) else 0,'ls':1 if (C or Z) else 0,
          'ge':1 if N==V else 0,'lt':1 if N!=V else 0,
          'gt':1 if (N==V and not Z) else 0,'le':1 if (Z or N!=V) else 0,
        }[cc]
    # ---- step ----
    def step(self):
        ins=self.prog.get(self.pc)
        if ins is None:
            # PC left valid code (corrupted return / smashed world):
            # raise a 68000 fault the OS can catch (odd->address error, else illegal instr).
            bad=self.pc
            self._faults=getattr(self,'_faults',{})
            self._faults[bad]=self._faults.get(bad,0)+1
            if self._faults[bad]>50:      # handler keeps returning here -> give up
                self.halted=True; return
            if bad&1: self.exception(3,bad,group0=True)
            else:     self.exception(4,bad)
            return
        self.pc=ins.nxt
        was_T=self.T
        try:
            self.exec(ins)
        except AddressError as ae:
            self.exception(3,ae.addr,group0=True)
            return
        if was_T and not self.halted:
            # trace: fire after instruction (unless we just entered an exception which cleared T)
            if (self.sr>>15)&1:
                self.exception(9,self.pc)
    def priv_check(self):
        if self.S==0:
            self.exception(8,self.pc)   # privilege violation; caller must abort
            return False
        return True
    def exec(self,ins):
        m=ins.mnem; sz=ins.size; ops=ins.ops
        P=self.parse_op
        if m=='nop': return
        if m=='move' or m=='movea':
            s=self.src(P(ops[0]),sz); d=P(ops[1])
            if d[0]=='sr' or d[0]=='usp':
                if not self.priv_check(): return
            if d[0]=='A' or m=='movea':
                self.A[d[1]]=SZSIGN[sz](s)&M32
            else:
                self.dst_write(d,sz,s)
                if d[0]!='sr': self.set_nz(s,sz)
            return
        if m=='moveq':
            v=s8(P(ops[0])[1]); self.D[P(ops[1])[1]]=v&M32; self.set_nz(v&M32,'l'); return
        if m=='movem':
            if '(' in ops[1]:           # store: movem reglist,<ea>
                regs=self._reglist(ops[0]); dop=P(ops[1])
                if dop[0]=='predec':
                    an=dop[1]
                    for rt,rn in reversed(regs):
                        self.A[an]=(self.A[an]-SZBYTES[sz])&M32
                        val=(self.D[rn] if rt=='D' else self.A[rn])&M32
                        self.write(self.A[an],sz,val)
                    return
                else:
                    addr=self.ea_addr(dop,sz)
                    for rt,rn in regs:
                        val=(self.D[rn] if rt=='D' else self.A[rn])&M32
                        self.write(addr,sz,val); addr=(addr+SZBYTES[sz])&M32
                    return
            else:                        # load: movem <ea>,reglist
                regs=self._reglist(ops[1]); sop=P(ops[0])
                if sop[0]=='postinc':
                    an=sop[1]
                    for rt,rn in regs:
                        val=self.read(self.A[an],sz); self.A[an]=(self.A[an]+SZBYTES[sz])&M32
                        v=SZSIGN[sz](val)&M32
                        if rt=='D': self.D[rn]=v
                        else: self.A[rn]=v
                    return
                else:
                    addr=self.ea_addr(sop,sz)
                    for rt,rn in regs:
                        val=SZSIGN[sz](self.read(addr,sz))&M32
                        if rt=='D': self.D[rn]=val
                        else: self.A[rn]=val
                        addr=(addr+SZBYTES[sz])&M32
                    return
        if m=='lea':
            self.A[P(ops[1])[1]]=self.ea_addr(P(ops[0]),'l')&M32; return
        if m=='clr':
            self.dst_write(P(ops[0]),sz,0); self.set_ccr(N=0,Z=1,V=0,C=0); return
        if m=='swap':
            n=P(ops[0])[1]; v=self.D[n]&M32; self.D[n]=((v>>16)|(v<<16))&M32; self.set_nz(self.D[n],'l'); return
        if m in('add','addq','adda'):
            s=self.src(P(ops[0]),sz); d=P(ops[1])
            if d[0]=='A' or m=='adda':
                self.A[d[1]]=(self.A[d[1]]+SZSIGN[sz](s))&M32; return
            a=self.src(d,sz); r=a+s; self.dst_write(d,sz,r); self.set_add(a,s,r,sz); return
        if m in('sub','subq','suba'):
            s=self.src(P(ops[0]),sz); d=P(ops[1])
            if d[0]=='A' or m=='suba':
                self.A[d[1]]=(self.A[d[1]]-SZSIGN[sz](s))&M32; return
            a=self.src(d,sz); r=self.set_sub(a,s,sz); self.dst_write(d,sz,r); return
        if m=='cmp':
            s=self.src(P(ops[0]),sz); a=self.src(P(ops[1]),sz); self.set_sub(a,s,sz); return
        if m=='tst':
            self.set_nz(self.src(P(ops[0]),sz),sz); return
        if m in('and','or','eor'):
            s=self.src(P(ops[0]),sz); d=P(ops[1]); a=self.src(d,sz)
            r=(a&s) if m=='and' else (a|s) if m=='or' else (a^s)
            if d[0]=='sr':
                if not self.priv_check(): return
                self.restore_sr(r&0xFFFF); return
            self.dst_write(d,sz,r); self.set_nz(r,sz); return
        if m in('andi','ori','eori'):
            s=P(ops[0])[1]; d=P(ops[1]); a=self.src(d,sz)
            r=(a&s) if m=='andi' else (a|s) if m=='ori' else (a^s)
            if d[0]=='sr':
                if not self.priv_check(): return
                self.restore_sr(r&0xFFFF); return
            self.dst_write(d,sz,r); self.set_nz(r,sz); return
        if m=='not':
            d=P(ops[0]); r=(~self.src(d,sz))&SZMASK[sz]; self.dst_write(d,sz,r); self.set_nz(r,sz); return
        if m=='neg':
            d=P(ops[0]); a=self.src(d,sz); r=self.set_sub(0,a,sz); self.dst_write(d,sz,r); return
        if m=='mulu':
            s=self.src(P(ops[0]),'w')&0xFFFF; d=P(ops[1]); a=self.D[d[1]]&0xFFFF
            r=(a*s)&M32; self.D[d[1]]=r; self.set_nz(r,'l'); return
        if m in('lsl','lsr','asl','asr','rol','ror'):
            cnt=P(ops[0]); d=P(ops[1])
            n=(cnt[1]&0xFFFFFFFF) if cnt[0]=='imm' else self.D[cnt[1]]&63
            v=self.src(d,sz); mm=SZMASK[sz]; bits=SZBYTES[sz]*8
            for _ in range(n%64 if m in('rol','ror') else n):
                if m in('lsl','asl'): v=(v<<1)&mm
                elif m in('lsr',): v=(v&mm)>>1
                elif m=='asr':
                    sign=v&((mm+1)>>1); v=((v&mm)>>1)|sign
                elif m=='rol': v=((v<<1)|((v>>(bits-1))&1))&mm
                elif m=='ror': v=((v>>1)|((v&1)<<(bits-1)))&mm
            self.dst_write(d,sz,v); self.set_nz(v,sz); return
        if m in('btst','bset','bclr','bchg'):
            bit=P(ops[0]); d=P(ops[1])
            bn=(bit[1] if bit[0]=='imm' else self.D[bit[1]])
            if d[0]=='D': bn%=32; v=self.D[d[1]]; szb='l'
            else: bn%=8; szb='b'; v=self.src(d,szb)
            self.set_ccr(Z=0 if (v>>bn)&1 else 1)
            if m!='btst':
                if m=='bset': v|=(1<<bn)
                elif m=='bclr': v&=~(1<<bn)
                else: v^=(1<<bn)
                self.dst_write(d,('l' if d[0]=='D' else 'b'),v)
            return
        if m=='dbra' or m=='dbf' or (m.startswith('db')):
            # dbcc: if cond true -> fall through; else dec Dn, if Dn!=-1 branch
            cc=m[2:] if len(m)>2 else 'f'
            d=P(ops[0]); tgt=P(ops[1])[1]
            if cc not in('ra','f') and self.cond(cc): return
            n=s16(self.D[d[1]]); n-=1
            self.D[d[1]]=(self.D[d[1]]&~0xFFFF)|(n&0xFFFF)
            if n!=-1: self.pc=tgt
            return
        if m=='bra' or m=='jmp':
            self.pc=P(ops[0])[1] if m=='bra' else self.ea_addr(P(ops[0]),'l'); return
        if m=='bsr' or m=='jsr':
            self.push32(self.pc)
            self.pc=P(ops[0])[1] if m=='bsr' else self.ea_addr(P(ops[0]),'l'); return
        if m=='rts':
            self.pc=self.read32(self.A[7]); self.A[7]=(self.A[7]+4)&M32; return
        if m=='rte':
            newsr=self.read16(self.A[7]); pc=self.read32(self.A[7]+2)
            self.A[7]=(self.A[7]+6)&M32
            self.restore_sr(newsr); self.pc=pc; return
        if m=='trap':
            n=P(ops[0])[1]; self.exception(32+n,self.pc); return
        if m[0]=='b' and len(m)>=3 and m[1:] in('eq','ne','cs','cc','lo','hs','mi','pl','vs','vc','hi','ls','ge','lt','gt','le'):
            if self.cond(m[1:]): self.pc=P(ops[0])[1]
            return
        raise Emu68kError("unimplemented instruction: %s (%s)"%(m,ins.text))
    def _is_mem(self,o):
        t=self.parse_op(o)[0]
        return t in('ind','postinc','predec','disp','index','abs','pcdisp','pcindex')
    def _reglist(self,o):
        regs=[]
        for part in o.split('/'):
            part=part.strip()
            mrange=re.fullmatch(r'([da])([0-7])-([da])([0-7])',part.lower())
            if mrange:
                t=mrange.group(1).upper(); a=int(mrange.group(2)); b=int(mrange.group(4))
                for n in range(a,b+1): regs.append((t,n))
            else:
                mm=re.fullmatch(r'([da])([0-7])',part.lower())
                regs.append((mm.group(1).upper(),int(mm.group(2))))
        return regs
    # ---- run ----
    def run(self,max_steps=2_000_000,frame_steps=3000,vblank=True,on_frame=None):
        next_vb=frame_steps
        while not self.halted and self.steps<max_steps:
            if vblank and self.steps>=next_vb:
                next_vb+=frame_steps
                if self.mask<6:
                    self.exception(30,self.pc,set_mask=6)
                if on_frame: on_frame(self)
            self.step()
            self.steps+=1
        return self

def run_program(files,**kw):
    syms,instrs,prog,mem=assemble(files)
    mac=Machine(syms,instrs,prog,mem)
    return mac.run(**kw), (syms,instrs,prog)

if __name__=='__main__':
    import sys
    mac,_=run_program(sys.argv[1:] or ['coop.asm'],max_steps=300000,frame_steps=2000)
    print("steps",mac.steps,"pc %06X"%mac.pc)
