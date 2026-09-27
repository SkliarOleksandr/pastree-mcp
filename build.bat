@echo off
rem Build pastree-mcp.exe (Win64) and run the smoke test over the fixture group.
rem It must end with "built, smoke test passed"; anything else is a failure.
rem
rem Takes the same arguments as scripts\ide.bat (copied from pastree-lsp): an
rem explicit RAD Studio version and/or --yes. The IDE does NOT have to be
rem closed - nothing here is loaded by it - but a Claude Code session may be
rem running out\pastree-mcp.exe as its MCP server; see the rename below.
rem
rem Requires PasTree as a sibling: ..\object-pascal-tree. It is the only
rem dependency, linked from source through -U. PASTREE set in the
rem environment builds against another copy instead - a snapshot of a commit
rem (git archive HEAD source) while the sibling is under edit by another
rem session, whose half-done change would otherwise go into this exe.
setlocal enabledelayedexpansion
cd /d "%~dp0"

call "%~dp0scripts\ide.bat" %*
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
rem up. The .old file is removed when nothing holds it any more.
if exist out\pastree-mcp.exe.old del /q out\pastree-mcp.exe.old >nul 2>&1
if exist out\pastree-mcp.exe move /y out\pastree-mcp.exe out\pastree-mcp.exe.old >nul 2>&1

echo === pastree-mcp.exe (Win64) ===
dcc64 -B -Q -GD ^
 -U"%BDS%\lib\win64\release" ^
 -U"%PASTREE%\source" ^
 -Usource ^
 "-NSSystem;System.Win;Winapi;Data;Xml" ^
 -N0"%DCU64%" -Eout pastree-mcp.dpr
if errorlevel 1 goto :fail
if exist out\pastree-mcp.exe.old del /q out\pastree-mcp.exe.old >nul 2>&1

"out\pastree-mcp.exe" --version
if errorlevel 1 goto :fail

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
