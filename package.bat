@echo off
setlocal
cd /d "%~dp0"

rem `package.bat`: the game as testers get it. A release build (optimized, no
rem console, its output and any crash in log.txt: release.odin) in
rem dist\EndlessTimeConsumingWorlds\ with everything it needs beside it, and
rem that folder zipped as dist\EndlessTimeConsumingWorlds-<version>.zip.
rem The version (date and commit, "-dirty" with uncommitted changes) shows in
rem the main menu's corner. The exe's debug symbols are kept out of the
rem folder, in dist\symbols\<version>.pdb, to read a tester's crash with.
rem It's built in dist\stage\ (wiped each time, zipped from there), then
rem copied over dist\EndlessTimeConsumingWorlds\: never wiped, as it's played
rem from, and its saves\ and log.txt are someone's.

set NAME=EndlessTimeConsumingWorlds
for /f %%h in ('git rev-parse --short HEAD') do set HASH=%%h
git diff --quiet HEAD -- . 2>nul || set HASH=%HASH%-dirty
for /f %%d in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set DAY=%%d
set VERSION=%DAY%-%HASH%
set OUT=dist\stage\%NAME%
set PLAY=dist\%NAME%
echo Packaging %NAME% %VERSION%

rem By its full path: a bare build.bat can be the Odin compiler's (on PATH).
call "%~dp0build.bat" shaders
if %errorlevel% neq 0 exit /b 1

if exist dist\stage rmdir /s /q dist\stage
mkdir "%OUT%"
if not exist dist\symbols mkdir dist\symbols

echo Building Odin... release
odin build . -o:speed -debug -subsystem:windows -define:RELEASE=true -define:VERSION=%VERSION% -out:%OUT%\%NAME%.exe
if %errorlevel% neq 0 (
    echo Odin build failed!
    exit /b 1
)
move /y "%OUT%\%NAME%.pdb" "dist\symbols\%VERSION%.pdb" >nul

copy /y SDL3.dll "%OUT%\" >nul
copy /y SDL3_ttf.dll "%OUT%\" >nul
xcopy /e /i /q /y resources "%OUT%\resources" >nul
> "%OUT%\version.txt" echo %VERSION%

set ZIP=dist\%NAME%-%VERSION%.zip
if exist "%ZIP%" del "%ZIP%"
powershell -NoProfile -Command "Compress-Archive -Path '%OUT%' -DestinationPath '%ZIP%'"
if %errorlevel% neq 0 (
    echo Zipping failed!
    exit /b 1
)
xcopy /e /i /q /y "%OUT%" "%PLAY%" >nul
rmdir /s /q dist\stage
echo Packaged: %PLAY%  and  %ZIP%
