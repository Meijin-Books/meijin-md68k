@echo off
vasmm68k_mot -Fbin -o hello.bin hello.asm
if errorlevel 1 goto fail
blastem hello.bin
goto end
:fail
echo ビルドに失敗しました
pause
:end
