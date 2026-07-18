@echo off
rem =================================================
rem  MeijinOS68k ── Windows用ビルド
rem
rem   使い方： build.bat          … 全部ビルド
rem            build.bat coop     … 一つだけビルド
rem            build.bat clean    … .bin を消す
rem
rem   必要なもの： vasmm68k_mot.exe に PATH が通っていること
rem                （または、このフォルダに置いてください）
rem =================================================

setlocal

set VASM=vasmm68k_mot
set VFLAGS=-Fbin

rem --- vasm があるか、先に確かめる ---
where %VASM% >nul 2>&1
if errorlevel 1 (
    if exist "%~dp0%VASM%.exe" (
        set VASM=%~dp0%VASM%.exe
    ) else (
        echo.
        echo [エラー] %VASM% が見つかりません。
        echo.
        echo   http://sun.hasenbraten.de/vasm/ から入手して、
        echo   PATH を通すか、このフォルダに置いてください。
        echo.
        exit /b 1
    )
)

rem --- clean ---
if /i "%~1"=="clean" (
    del /q coop.bin preempt.bin meijin10.bin trace.bin crash.bin 2>nul
    del /q *.lst 2>nul
    echo きれいにしました。
    exit /b 0
)

rem --- 一つだけビルド ---
if not "%~1"=="" (
    call :build %~1
    exit /b %errorlevel%
)

rem --- 全部ビルド ---
set FAILED=0
for %%F in (coop preempt meijin10 trace crash) do (
    call :build %%F
    if errorlevel 1 set FAILED=1
)

if %FAILED%==1 (
    echo.
    echo ビルドに失敗したものがあります。
    exit /b 1
)

echo.
echo すべてビルドできました。
echo BlastEm などのエミュレータに .bin を放り込んでください。
exit /b 0

rem =================================================
:build
echo [%~1.asm] をビルドしています...
%VASM% %VFLAGS% -o %~1.bin %~1.asm
if errorlevel 1 (
    echo   → 失敗しました。
    exit /b 1
)
echo   → %~1.bin ができました。
exit /b 0
