# =================================================
# MeijinOS68k ── ビルド
#   必要なもの： vasm (m68k / Motorola syntax)
#
#   make          … 全部ビルド
#   make verify   … ビルドして、実際に走らせて検証
#   make clean    … .bin を消す
#
#   Windowsで make が無い場合は、build.bat を使ってください。
# =================================================

VASM   ?= vasmm68k_mot
VFLAGS ?= -Fbin

TARGETS = coop.bin preempt.bin meijin10.bin trace.bin crash.bin
DEPS    = vdp.asm font.asm

all: $(TARGETS)

%.bin: %.asm $(DEPS)
	$(VASM) $(VFLAGS) -o $@ $<

verify: all
	python3 tools/verify.py

clean:
	rm -f $(TARGETS) *.lst

.PHONY: all verify clean
