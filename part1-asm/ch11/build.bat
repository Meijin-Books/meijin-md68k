@echo off
vasmm68k_mot -Fbin -o move.bin move.asm
if errorlevel 1 goto fail
blastem move.bin
goto end
:fail
echo ビルドに失敗しました
pause
:end
