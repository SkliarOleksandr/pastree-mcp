unit PasMcp.Studio;

{
  Which RAD Studio the analysis emulates, and the library directories that
  installation adds to every project's search path.

  pastree-lsp gets these from the IDE plugin (the `searchPaths` /
  `libraryPaths` initialization options); this server has no IDE to ask, so it
  reads the registry the way PasTree's demo does (PasTreeDemo.Main,
  ExtraSearchPaths): HKCU\Software\Embarcadero\BDS\<ver>\Library\<Platform>,
  `Search Path` then `Browsing Path`, with $(BDS), $(BDSLIB), $(Platform) and
  the user macros from `Environment Variables` expanded. A third-party suite
  (DevExpress, JCL, ...) is visible ONLY through these paths, and a unit that
  does not resolve silences its importers' diagnostics rather than reporting
  them - so a thin library path reads as "clean", not as "incomplete".

  The Studio SOURCE trees are appended after the registry paths
  (PasTreeSemaProject's StudioSearchPaths list): a registry with no browsing
  path still resolves System.*, Vcl.* and FMX.*.
}

interface

uses
  System.Generics.Collections,
  PasTree.Platforms;

type
  TMcpStudio = record
    Version: string;          // registry key, '37.0'
    Root: string;             // RootDir, no trailing backslash
    CompilerVersion: Double;  // dcc version the analysis emulates
    function Found: Boolean;
    // Registry library + browsing paths, then the Studio source trees; only
    // existing directories, de-duplicated, in that order.
    function LibraryPaths(APlatform: TPasPlatform): TArray<string>;
    // The registry library `Search Path` alone, expanded the same way: what
    // dcc searches for a project with no search path of its own (`compile`
    // of a bare .dpr). Not the browsing path or the source trees - dcc would
    // recompile the sources it found there.
    function SearchPath(APlatform: TPasPlatform): TArray<string>;
    // The IDE's own environment variables (Tools > Options > Environment
    // Variables, the registry's `Environment Variables` key), values as
    // stored: one may name another, or the process environment, as $(NAME).
    // The IDE sets them for every build it runs, and a library path names
    // them - a command-line build without them loses those directories.
    function IdeVariables: TArray<TPair<string, string>>;
  end;

// AWanted = '' picks $BDS when set, else the highest installed version.
// Result.Found = False when no installation is registered.
function FindStudio(const AWanted: string): TMcpStudio;

// Every installed version, highest first ('37.0', '23.0', ...).
function InstalledStudioVersions: TArray<string>;

// The installed version AText names - a BDS version ('23.0', '23'), a dcc
// version ('36.0') or a Delphi one ('Delphi 12', '12 Athens', 'Athens') -
// or '' when none does. For `compile`'s `studio`.
function StudioNamed(const AText: string): string;

// The installed versions, highest first, each with its compiler and Delphi
// version: '37.0 (dcc 37.0, Delphi 13 Florence), 23.0 (dcc 36.0, Delphi 12
// Athens)'; 'none' when none is.
function InstalledStudiosText: string;

// What an agent writing code for AStudio's compiler must know of the
// language: the Delphi version, the constructs newer versions added that
// this one rejects, how to try one, and where the language reference is.
// For the server's instructions and `status`; '' when no Studio was found.
function LanguageNote(const AStudio: TMcpStudio): string;

// 'Delphi 11 Alexandria' for dcc 35.0; '' for one before 10 Seattle.
function DelphiName(ACompiler: Double): string;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Math,
  System.StrUtils,
  System.Generics.Defaults,
  System.Win.Registry,
  Winapi.Windows;

const
  BDS_KEY = 'SOFTWARE\Embarcadero\BDS';

function VersionNumber(const AKey: string): Double;
begin
  if not TryStrToFloat(AKey, Result, TFormatSettings.Invariant) then
    Result := -1;
end;

// BDS 22.0 is dcc 35.0 and 23.0 is 36.0; the numbers met again at 13
// (37.0). The same mapping as the demo's ApplyStudio.
function CompilerOf(const AVersion: string): Double;
begin
  Result := VersionNumber(AVersion);
  if SameValue(Result, 22.0) then
    Result := 35.0
  else if SameValue(Result, 23.0) then
    Result := 36.0;
end;

function InstalledStudioVersions: TArray<string>;
var
  LReg: TRegistry;
  LKeys: TStringList;
  LList: TList<string>;
begin
  LList := TList<string>.Create;
  LKeys := TStringList.Create;
  LReg := TRegistry.Create(KEY_READ);
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if LReg.OpenKeyReadOnly(BDS_KEY) then
    begin
      LReg.GetKeyNames(LKeys);
      for var LKey in LKeys do
        if (VersionNumber(LKey) > 0) and
           LReg.OpenKeyReadOnly('\' + BDS_KEY + '\' + LKey) and
           (LReg.ReadString('RootDir') <> '') and
           TDirectory.Exists(LReg.ReadString('RootDir')) then
          LList.Add(LKey);
    end;
    LList.Sort(TComparer<string>.Construct(
      function(const L, R: string): Integer
      begin
        Result := CompareValue(VersionNumber(R), VersionNumber(L));
      end));
    Result := LList.ToArray;
  finally
    LReg.Free;
    LKeys.Free;
    LList.Free;
  end;
end;

function RootOf(const AVersion: string): string;
var
  LReg: TRegistry;
begin
  Result := '';
  LReg := TRegistry.Create(KEY_READ);
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if LReg.OpenKeyReadOnly(BDS_KEY + '\' + AVersion) then
      Result := ExcludeTrailingPathDelimiter(LReg.ReadString('RootDir'));
  finally
    LReg.Free;
  end;
end;

function FindStudio(const AWanted: string): TMcpStudio;
var
  LVersions: TArray<string>;
  LBds: string;
begin
  Result := Default(TMcpStudio);
  LVersions := InstalledStudioVersions;
  if AWanted <> '' then
  begin
    for var LV in LVersions do
      if SameText(LV, AWanted) then
        Result.Version := LV;
  end
  else
  begin
    LBds := ExcludeTrailingPathDelimiter(GetEnvironmentVariable('BDS'));
    for var LV in LVersions do
      if (LBds <> '') and SameText(RootOf(LV), LBds) then
        Result.Version := LV;
    if (Result.Version = '') and (Length(LVersions) > 0) then
      Result.Version := LVersions[0];
  end;
  if Result.Version = '' then
    Exit;
  Result.Root := RootOf(Result.Version);
  Result.CompilerVersion := CompilerOf(Result.Version);
end;

function StudioNamed(const AText: string): string;
var
  LText: string;
  LNumber: Double;
begin
  Result := '';
  LText := Trim(AText);
  if LText = '' then
    Exit;
  // A BDS version first: 37.0 is both 13's BDS and its dcc version.
  if TryStrToFloat(LText, LNumber, TFormatSettings.Invariant) then
  begin
    for var LV in InstalledStudioVersions do
      if SameValue(VersionNumber(LV), LNumber) then
        Exit(LV);
    for var LV in InstalledStudioVersions do
      if SameValue(CompilerOf(LV), LNumber) then
        Exit(LV);
  end;
  // 'Delphi 12', '12 Athens', 'Athens': the words of its Delphi name.
  if not StartsText('Delphi ', LText) then
    LText := 'Delphi ' + LText;
  for var LV in InstalledStudioVersions do
    if (DelphiName(CompilerOf(LV)) <> '') and (StartsText(LText + ' ',
      DelphiName(CompilerOf(LV)) + ' ') or EndsText(' ' + Copy(LText, 8,
      MaxInt), DelphiName(CompilerOf(LV)))) then
      Exit(LV);
end;

function InstalledStudiosText: string;
var
  LName: string;
begin
  Result := '';
  for var LV in InstalledStudioVersions do
  begin
    LName := DelphiName(CompilerOf(LV));
    Result := Result + IfThen(Result <> '', ', ', '') + Format('%s (dcc %.1f%s)',
      [LV, CompilerOf(LV), IfThen(LName <> '', ', ' + LName, '')],
      TFormatSettings.Invariant);
  end;
  if Result = '' then
    Result := 'none';
end;

function TMcpStudio.Found: Boolean;
begin
  Result := Root <> '';
end;

// The registry library paths of APlatform, expanded: the `Search Path`, and
// with ABrowsing the `Browsing Path` and the Studio source trees after it.
function RegistryPaths(const AStudio: TMcpStudio; APlatform: TPasPlatform;
  ABrowsing: Boolean): TArray<string>;
const
  SOURCE_TREES: array[0..8] of string = ('source\rtl\sys',
    'source\rtl\common', 'source\rtl\win', 'source\rtl\win\winrt',
    'source\rtl\net', 'source\databinding\engine', 'source\xml',
    'source\vcl', 'source\fmx');
var
  LList: TList<string>;
  LSeen: TDictionary<string, Boolean>;
  LVars: TDictionary<string, string>;
  LReg: TRegistry;
  LNames: TStringList;
  LKey, LPlat: string;

  function Expand(const APath: string): string;
  var
    LFrom, LTo: Integer;
    LName, LVal: string;
  begin
    Result := APath;
    LFrom := Pos('$(', Result);
    while LFrom > 0 do
    begin
      LTo := Pos(')', Result, LFrom);
      if LTo = 0 then
        Exit;
      LName := Copy(Result, LFrom + 2, LTo - LFrom - 2);
      if not LVars.TryGetValue(LowerCase(LName), LVal) then
        LVal := GetEnvironmentVariable(LName);
      Result := Copy(Result, 1, LFrom - 1) + LVal + Copy(Result, LTo + 1,
        MaxInt);
      LFrom := Pos('$(', Result);
    end;
  end;

  procedure AddPaths(const ASemiList: string);
  var
    LDir: string;
  begin
    for var LOne in ASemiList.Split([';']) do
    begin
      LDir := Expand(Trim(LOne));
      if (LDir = '') or (Pos('$(', LDir) > 0) then
        Continue;
      LDir := ExcludeTrailingPathDelimiter(LDir);
      if TDirectory.Exists(LDir) and not LSeen.ContainsKey(LowerCase(LDir)) then
      begin
        LSeen.Add(LowerCase(LDir), True);
        LList.Add(LDir);
      end;
    end;
  end;

begin
  Result := nil;
  if not AStudio.Found then
    Exit;
  if APlatform = pfWin64 then
    LPlat := 'Win64'
  else
    LPlat := 'Win32';
  LList := TList<string>.Create;
  LSeen := TDictionary<string, Boolean>.Create;
  LVars := TDictionary<string, string>.Create;
  LNames := TStringList.Create;
  LReg := TRegistry.Create(KEY_READ);
  try
    LVars.AddOrSetValue('bds', AStudio.Root);
    LVars.AddOrSetValue('bdslib', TPath.Combine(AStudio.Root, 'lib'));
    LVars.AddOrSetValue('platform', LPlat);
    for var LPair in AStudio.IdeVariables do
      LVars.AddOrSetValue(LowerCase(LPair.Key), LPair.Value);
    LReg.RootKey := HKEY_CURRENT_USER;
    LKey := '\' + BDS_KEY + '\' + AStudio.Version;
    if LReg.OpenKeyReadOnly(LKey + '\Library\' + LPlat) then
    begin
      AddPaths(LReg.ReadString('Search Path'));
      if ABrowsing then
        AddPaths(LReg.ReadString('Browsing Path'));
    end;
    if ABrowsing then
      for var LSub in SOURCE_TREES do
        AddPaths(TPath.Combine(AStudio.Root, LSub));
    Result := LList.ToArray;
  finally
    LReg.Free;
    LNames.Free;
    LVars.Free;
    LSeen.Free;
    LList.Free;
  end;
end;

function TMcpStudio.LibraryPaths(APlatform: TPasPlatform): TArray<string>;
begin
  Result := RegistryPaths(Self, APlatform, True);
end;

function TMcpStudio.SearchPath(APlatform: TPasPlatform): TArray<string>;
begin
  Result := RegistryPaths(Self, APlatform, False);
end;

function TMcpStudio.IdeVariables: TArray<TPair<string, string>>;
var
  LReg: TRegistry;
  LNames: TStringList;
begin
  Result := nil;
  if not Found then
    Exit;
  LNames := TStringList.Create;
  LReg := TRegistry.Create(KEY_READ);
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if LReg.OpenKeyReadOnly('\' + BDS_KEY + '\' + Version +
      '\Environment Variables') then
    begin
      LReg.GetValueNames(LNames);
      for var LName in LNames do
        if LName <> '' then
          Result := Result + [TPair<string, string>.Create(LName,
            LReg.ReadString(LName))];
    end;
  finally
    LReg.Free;
    LNames.Free;
  end;
end;

type
  TLanguageStep = record
    Compiler: Double;
    Delphi: string;
    Added: string;
  end;

const
  // The language constructs each compiler version added, from the language
  // reference's version history (object-pascal-spec, Appendix A): the ones an
  // agent writes by habit and an older compiler rejects. Before 10.3 the
  // steps are too far back to matter.
  LANGUAGE_STEPS: array[0..4] of TLanguageStep = (
    (Compiler: 33.0; Delphi: '10.3 Rio';
     Added: 'inline variables and constants (var X := ... inside a block)'),
    (Compiler: 34.0; Delphi: '10.4 Sydney';
     Added: 'custom managed records (class operator Initialize, Finalize, '
       + 'Assign)'),
    (Compiler: 35.0; Delphi: '11 Alexandria';
     Added: 'binary literals (%1010), the digit separator (1_000)'),
    (Compiler: 36.0; Delphi: '12 Athens';
     Added: 'multiline string literals (''''''...'''''')'),
    (Compiler: 37.0; Delphi: '13 Florence';
     Added: 'if-expressions (X := if C then A else B), NameOf, `is not` and '
       + '`not in`, {$PUSHOPT}/{$POPOPT}, noreturn'));

  LANGUAGE_REFERENCE = 'https://github.com/SkliarOleksandr/object-pascal-spec';

function DelphiName(ACompiler: Double): string;
const
  OLDER: array[30..32] of string = ('10 Seattle', '10.1 Berlin', '10.2 Tokyo');
begin
  Result := '';
  for var LStep in LANGUAGE_STEPS do
    if SameValue(LStep.Compiler, ACompiler) then
      Exit('Delphi ' + LStep.Delphi);
  for var LV := Low(OLDER) to High(OLDER) do
    if SameValue(LV, ACompiler) then
      Exit('Delphi ' + OLDER[LV]);
end;

function LanguageNote(const AStudio: TMcpStudio): string;
var
  LName, LMissing: string;
  LNewest: Integer;
begin
  Result := '';
  if not AStudio.Found then
    Exit;
  LName := DelphiName(AStudio.CompilerVersion);
  Result := Format('Compiler: dcc %.1f%s.', [AStudio.CompilerVersion,
    IfThen(LName <> '', ' (' + LName + ')', '')], TFormatSettings.Invariant);
  LMissing := '';
  LNewest := -1;
  for var LI := Low(LANGUAGE_STEPS) to High(LANGUAGE_STEPS) do
    if LANGUAGE_STEPS[LI].Compiler > AStudio.CompilerVersion + 0.05 then
      LMissing := LMissing + IfThen(LMissing <> '', '; ', '')
        + LANGUAGE_STEPS[LI].Added + ' - Delphi ' + LANGUAGE_STEPS[LI].Delphi
    else
      LNewest := LI;
  // Named even when nothing is missing: an agent unsure of the newest
  // constructs otherwise compiles a probe to learn they are there.
  if LNewest >= 0 then
    Result := Result + ' Its newest constructs, which compile here: '
      + LANGUAGE_STEPS[LNewest].Added + IfThen(SameValue(
      LANGUAGE_STEPS[LNewest].Compiler, AStudio.CompilerVersion), '',
      ' - Delphi ' + LANGUAGE_STEPS[LNewest].Delphi) + '.';
  if LMissing <> '' then
    Result := Result + ' Not in this version, so not to be written here: '
      + LMissing + '.';
  Result := Result + ' Whether a construct compiles here: `compile` with '
    + '`code`. The language rules, each checked against dcc: '
    + LANGUAGE_REFERENCE + '.';
end;

end.
