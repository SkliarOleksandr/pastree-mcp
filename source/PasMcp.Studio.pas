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
  end;

// AWanted = '' picks $BDS when set, else the highest installed version.
// Result.Found = False when no installation is registered.
function FindStudio(const AWanted: string): TMcpStudio;

// Every installed version, highest first ('37.0', '23.0', ...).
function InstalledStudioVersions: TArray<string>;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Math,
  System.Generics.Collections,
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
  // BDS 22.0 is dcc 35.0 and 23.0 is 36.0; the numbers met again at 13
  // (37.0). The same mapping as the demo's ApplyStudio.
  Result.CompilerVersion := VersionNumber(Result.Version);
  if SameValue(Result.CompilerVersion, 22.0) then
    Result.CompilerVersion := 35.0
  else if SameValue(Result.CompilerVersion, 23.0) then
    Result.CompilerVersion := 36.0;
end;

function TMcpStudio.Found: Boolean;
begin
  Result := Root <> '';
end;

function TMcpStudio.LibraryPaths(APlatform: TPasPlatform): TArray<string>;
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
  if not Found then
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
    LVars.AddOrSetValue('bds', Root);
    LVars.AddOrSetValue('bdslib', TPath.Combine(Root, 'lib'));
    LVars.AddOrSetValue('platform', LPlat);
    LReg.RootKey := HKEY_CURRENT_USER;
    LKey := '\' + BDS_KEY + '\' + Version;
    if LReg.OpenKeyReadOnly(LKey + '\Environment Variables') then
    begin
      LReg.GetValueNames(LNames);
      for var LName in LNames do
        LVars.AddOrSetValue(LowerCase(LName), LReg.ReadString(LName));
    end;
    if LReg.OpenKeyReadOnly(LKey + '\Library\' + LPlat) then
    begin
      AddPaths(LReg.ReadString('Search Path'));
      AddPaths(LReg.ReadString('Browsing Path'));
    end;
    for var LSub in SOURCE_TREES do
      AddPaths(TPath.Combine(Root, LSub));
    Result := LList.ToArray;
  finally
    LReg.Free;
    LNames.Free;
    LVars.Free;
    LSeen.Free;
    LList.Free;
  end;
end;

end.
