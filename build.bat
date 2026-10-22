@echo off
rem Build pastree-mcp.exe (Win64) and, with --test, run the smoke test over the
rem fixture group.
rem
rem Takes the same arguments as scripts\ide.bat (copied from pastree-lsp): an
rem explicit RAD Studio version and/or --yes. Plus one of its own:
rem
rem   --test   run tests\smoke.ps1 after building.
rem
rem THE SMOKE TEST RUNS ONLY ON REQUEST, as in pastree-lsp. It starts the
rem server over the fixture many times, compiles the fixture for real and grows
rem with every tool; a rebuild before restarting a session gets nothing from
rem that wait (Alex, 2026-10-22). A change is not verified until
rem "build.bat --test" ends with "built, smoke test passed"; anything else is
rem a failure.
rem
rem The IDE does NOT have to be closed - nothing here is loaded by it - but a Claude Code session may be
rem running out\pastree-mcp.exe as its MCP server; see the rename below.
rem
rem Requires PasTree as a sibling: ..\object-pascal-tree. It is the only
rem dependency, linked from source through -U. PASTREE set in the
rem environment builds against another copy instead - a snapshot of a commit
rem (git archive HEAD source) while the sibling is under edit by another
rem session, whose half-done change would otherwise go into this exe.
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem --test is this script's alone: scripts\ide.bat takes any word it does not
rem know for a RAD Studio version, so it is taken out before the rest goes on.
rem SHIFT MOVES %0 TOO, so the script's own directory is kept before the loop:
rem %~dp0 after it names wherever the last argument pointed.
set "LHERE=%~dp0"
set "LRUNTESTS="
set "LIDEARGS="
:args
if "%~1"=="" goto :argsdone
if /i "%~1"=="--test" (
  set "LRUNTESTS=1"
) else (
  set "LIDEARGS=!LIDEARGS! %1"
)
shift
goto :args
:argsdone

call "%LHERE%scripts\ide.bat" %LIDEARGS%
if errorlevel 1 exit /b 1
call "%BDSROOT%\bin\rsvars.bat"

if not defined PASTREE set PASTREE=..\object-pascal-tree
if not exist "%PASTREE%\source" (
  echo === PasTree not found next to this repo, cloning it ===
  git clone https://github.com/SkliarOleksandr/object-pascal-tree.git "%PASTREE%"
  if errorlevel 1 goto :fail
)
rem Which PasTree went in - the directory, the commit and whether its working
rem tree is ahead of it (that checkout is edited by other sessions; a build from
rem uncommitted changes is not reproducible from the hash).
echo === PasTree sources ===
for %%D in ("%PASTREE%") do echo   dir:     %%~fD
set "LDIRTY="
for /f "delims=" %%S in ('git -C "%PASTREE%" status --porcelain --untracked-files^=no 2^>nul') do set "LDIRTY= + uncommitted changes"
git -C "%PASTREE%" log -1 --format="  commit:  %%h %%d!LDIRTY!" 2>nul
findstr /c:"PasTreeVersion = " "%PASTREE%\source\PasTree.Version.pas"

rem Every .dcu under out\dcu\<RAD Studio version>\win64, never beside a source:
rem .dcu files are not portable between compiler versions.
set DCU64=out\dcu\%BDSVER%\win64
if not exist "%DCU64%" mkdir "%DCU64%"

rem A RUNNING SERVER HOLDS THE EXE: Claude Code starts out\pastree-mcp.exe per
rem session and keeps it. Windows lets a running exe be RENAMED, so the old one
rem moves aside, the build writes a fresh file, and the next session picks it
rem up. The .old files are removed when nothing holds them any more. Sessions
rem of two builds ago may still hold .old itself: then the exe moves to a name
rem of its own, or it stays in place and dcc cannot write it (F2039).
for %%F in (out\pastree-mcp.exe.old*) do del /q "%%F" >nul 2>&1
if exist out\pastree-mcp.exe move /y out\pastree-mcp.exe out\pastree-mcp.exe.old >nul 2>&1
if exist out\pastree-mcp.exe move /y out\pastree-mcp.exe "out\pastree-mcp.exe.old-%RANDOM%" >nul 2>&1

echo === pastree-mcp.exe (Win64) ===
dcc64 -B -Q -GD ^
 -U"%BDS%\lib\win64\release" ^
 -U"%PASTREE%\source" ^
 -Usource ^
 "-NSSystem;System.Win;Winapi;Data;Xml" ^
 -N0"%DCU64%" -Eout pastree-mcp.dpr
if errorlevel 1 goto :fail
for %%F in (out\pastree-mcp.exe.old*) do del /q "%%F" >nul 2>&1

"out\pastree-mcp.exe" --version
if errorlevel 1 goto :fail

if not defined LRUNTESTS (
  echo.
  echo built, smoke test not run ^(build.bat --test runs it^)
  exit /b 0
)

echo === smoke test ===
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 -Exe "%CD%\out\pastree-mcp.exe"
if errorlevel 1 goto :fail

echo.
echo built, smoke test passed
exit /b 0

:fail
echo.
echo BUILD FAILED
exit /b 1
