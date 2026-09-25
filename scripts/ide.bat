@echo off
rem Decide which RAD Studio installation this run targets, and export it as
rem BDSVER (e.g. "37.0") and BDSROOT (that installation's directory). The
rem caller then invokes "%BDSROOT%\bin\rsvars.bat" itself - rsvars sets PATH,
rem BDS and friends, and those would be lost across this script's endlocal.
rem
rem ONE PLACE, BECAUSE THE ANSWER MUST BE THE SAME FOR BOTH USES. A designtime
rem BPL loads only in the compiler version that produced it. So "which Delphi
rem builds the package" and "which Delphi gets the package registered" are not
rem two questions: a build.bat with 37.0 hardcoded next to an install.bat that
rem picked something else would register a BPL the IDE silently declines to
rem load, and the symptom - a plugin that is installed and simply does nothing -
rem names no cause at all.
rem
rem Usage:  call scripts\ide.bat [version] [--yes]
rem   version  an installed one, e.g. 37.0 - skips every question.
rem   --yes    never prompt; take the newest suitable version.
rem %PASTREE_IDE_VERSION% means the same as the version argument.
rem
rem THE PROMPT IS THE LAST RESORT, not the normal path: an explicit version
rem answers it, and so does having exactly one suitable installation, which is
rem the common case. It also has to happen HERE, before the caller starts
rem building - a question that surfaces after several minutes of compiling is
rem a question asked at the worst possible moment.
setlocal enabledelayedexpansion

set "LWANT=%~1"
set "LYES="
if /i "%~1"=="--yes" (
  set "LYES=1"
  set "LWANT="
)
if /i "%~2"=="--yes" set "LYES=1"
if not defined LWANT if defined PASTREE_IDE_VERSION set "LWANT=%PASTREE_IDE_VERSION%"

rem The floor is a real requirement, not caution: the package targets Delphi 12
rem and newer (see README.md).
rem
rem DELPHI 12 ATHENS IS BDS 23.0 - the registry key is the IDE's own version,
rem which has not matched the product name since "Delphi 10 Seattle" was 17.0:
rem 10.4 Sydney 21.0, 11 Alexandria 22.0, 12 Athens 23.0, 13 Florence 37.0.
rem Written down because the first draft of this file guessed 29.0 for Delphi
rem 12, and the effect was not a crash: it silently withheld an installed,
rem perfectly suitable IDE and called it too old. Change this only against the
rem actual key under HKCU\Software\Embarcadero\BDS on a machine that has the
rem version in question.
set "LMINMAJOR=23"

set "LCOUNT=0"
set "LOLD="
for /f "tokens=5 delims=\" %%V in ('reg query "HKCU\Software\Embarcadero\BDS" 2^>nul') do (
  if not "%%V"=="" call :probe "%%V"
)

for /l %%I in (1,1,%LCOUNT%) do set "LLIST=!LLIST! !LVER[%%I]!"

if %LCOUNT%==0 (
  echo.
  echo No suitable RAD Studio installation found.
  if defined LOLD echo Installed but too old:!LOLD!
  echo This package needs Delphi 12 ^(BDS 23.0^) or newer.
  goto :fail
)

rem An explicit version is honoured only if it is one of the suitable ones. The
rem two ways it can fail need different messages, so they get different ones.
if defined LWANT (
  for /l %%I in (1,1,%LCOUNT%) do (
    if "!LVER[%%I]!"=="%LWANT%" set "LPICK=%%I"
  )
  if not defined LPICK (
    echo.
    echo RAD Studio %LWANT% is not available for this build.
    if defined LOLD echo Installed but too old:!LOLD!
    echo Suitable:!LLIST!
    goto :fail
  )
  goto :chosen
)

if %LCOUNT%==1 (
  set "LPICK=1"
  goto :chosen
)

rem The candidates are held newest first (see :probe), so the newest is [1].
if defined LYES (
  set "LPICK=1"
  goto :chosen
)

echo.
echo Which RAD Studio should this target?
set "LKEYS="
for /l %%I in (1,1,%LCOUNT%) do (
  echo   [%%I] !LVER[%%I]!  !LROOT[%%I]!
  set "LKEYS=!LKEYS!%%I"
)
if defined LOLD echo   ^(too old for this package, not offered:!LOLD! ^)
choice /c !LKEYS! /n /m "Choose [1-%LCOUNT%]: "
set "LPICK=!errorlevel!"

:chosen
for %%I in (!LPICK!) do (
  set "LVER=!LVER[%%I]!"
  set "LROOT=!LROOT[%%I]!"
)
echo Targeting RAD Studio !LVER!  ^(!LROOT!^)
endlocal & set "BDSVER=%LVER%" & set "BDSROOT=%LROOT%"
exit /b 0

:fail
endlocal
exit /b 1

rem ---------------------------------------------------------------------------
rem One candidate version key. A key under BDS is not proof of an installation -
rem an uninstall can leave one behind - so the test that counts is whether
rem rsvars.bat is actually there, which is also the file the caller needs next.
:probe
set "LV=%~1"
rem Parsed without piping through find/findstr ON PURPOSE. This script is run
rem from Git Bash as often as from cmd, and there `find` resolves to the Unix
rem one, which reads the pipe as a path and reports nothing - leaving the
rem script to announce that no RAD Studio is installed on a machine that has
rem two. Matching on the value name instead needs no external tool at all:
rem reg prints "RootDir  REG_SZ  <path>", and every other line of its output
rem has something else in the first token.
set "LR="
for /f "tokens=1,2,*" %%A in ('reg query "HKCU\Software\Embarcadero\BDS\%LV%" /v RootDir 2^>nul') do (
  if /i "%%A"=="RootDir" set "LR=%%C"
)
if not defined LR exit /b 0
if "!LR:~-1!"=="\" set "LR=!LR:~0,-1!"
if not exist "!LR!\bin\rsvars.bat" exit /b 0

for /f "tokens=1 delims=." %%M in ("%LV%") do set "LMAJOR=%%M"
if !LMAJOR! lss %LMINMAJOR% (
  set "LOLD=!LOLD! %LV%"
  exit /b 0
)

rem KEPT NEWEST FIRST, by insertion rather than by enumeration order: reg query
rem lists subkeys as text, so it would put "10.0" ahead of "9.0". Sorting once,
rem here, is what makes the menu, the "Suitable:" line and the --yes pick agree,
rem and it puts the newest IDE - the one meant in the common case - at [1].
set /a LCOUNT+=1
set "LPOS=!LCOUNT!"
:insert
if !LPOS! gtr 1 (
  set /a LPREV=!LPOS!-1
  call set "LPV=%%LVER[!LPREV!]%%"
  for /f "tokens=1 delims=." %%M in ("!LPV!") do set "LPMAJOR=%%M"
  if !LMAJOR! gtr !LPMAJOR! (
    call set "LVER[!LPOS!]=%%LVER[!LPREV!]%%"
    call set "LROOT[!LPOS!]=%%LROOT[!LPREV!]%%"
    set "LPOS=!LPREV!"
    goto :insert
  )
)
set "LVER[!LPOS!]=%LV%"
set "LROOT[!LPOS!]=!LR!"
exit /b 0
