unit PasMcp.Workspace;

{
  The analyzed world behind every tool: a project group (or one project), read
  from disk, analyzed by PasTree, and kept in step with the files as they
  change underneath it.

  GROUPS, AND WHY NOT ONE ANALYSIS PER PROJECT. pastree-lsp runs one server -
  one TPasSemaProject - per project of a group, and on the client group that is
  3.5-4 GB per process: nine members would not fit on the machines this runs
  on. Most of a group's closure is SHARED (the RTL/VCL, the component suites,
  the application's own core units), and TPasSemaProject caches units by full
  path, so members folded into ONE analysis parse each shared unit once. That
  is what an "analysis" is here (TMcpAnalysis): one TPasSemaProject over one or
  more members, whose main sources are all roots of the same AnalyzeStaged run.

  What decides which members share one analysis (TMcpGroupPolicy):
  - gpShared (default): one analysis per PLATFORM. The defines, namespaces and
    aliases come from the PRIMARY member - the one listing the most files - and
    every member whose defines differ is logged. Approximate on purpose: a unit
    that compiles differently per project is analyzed with the primary's
    defines, which is the right trade for "find where X is used" questions and
    the wrong one for "which branch does project B compile".
  - gpStrict: one analysis per distinct (platform, defines, namespaces,
    aliases) - exact, and as memory-hungry as that sounds.
  Under both, a member that lists a DIFFERENT file for a unit name another
  member of the analysis already pinned gets an analysis of its own: one
  analysis can hold only one `Foo.pas`.

  FRESHNESS. The agent this serves edits the files it asks about, so a stale
  index answers with line numbers that are no longer true - worse than no
  answer. Every tool call runs EnsureFresh first: each OWN file (see IsOwnFile)
  and each project file has its write time and size recorded at build; a
  change re-analyzes just that module (AnalyzeModuleOnly), and a refusal there,
  a deleted file or a changed include falls back to a full rebuild that adopts
  the previous analysis as its parse donor. What a module run takes in - a unit
  a changed uses clause adds, an include a changed unit now pulls in - is
  stamped after it (StampNewcomers), or its later edits would go unseen. A
  changed .dproj/.groupproj reloads the whole workspace. Library files are not
  watched.

  MEMORY. After every build, DemoteText frees the text layer of every library
  unit (positions and snippets come back through EnsureHydrated on demand) and
  keeps the own units warm, which is also what keeps AnalyzeModuleOnly usable
  for them - it refuses a demoted model.

  THREADING. Load runs once on a background thread so the MCP handshake does
  not wait for a closure-sized analysis; tools wait on Ready. After that,
  everything happens on the request thread, one call at a time.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  PasTree.Platforms,
  PasTree.DProj,
  PasTree.Sema.Model,
  PasTree.Sema.Project,
  PasTree.Sema.Nav,
  PasMcp.Studio;

type
  TMcpGroupPolicy = (gpShared, gpStrict);

  TMcpMember = record
    ProjectFile: string;     // .dproj or .dpr
    Name: string;
    MainSource: string;
    Platform: TPasPlatform;
    Config: string;
    SearchPaths: TArray<string>;
    Defines: TArray<string>;
    Namespaces: TArray<string>;
    Aliases: TArray<TPasUnitAlias>;
    Files: TArray<string>;   // the .pas files the project lists
    Analysis: Integer;       // index into TMcpWorkspace.Analyses; -1 = failed
    Error: string;
  end;

  TMcpFileStamp = record
    Time: TDateTime;
    Size: Int64;
  end;

  TMcpAnalysis = class
  public
    Index: Integer;
    Members: TArray<Integer>;
    Platform: TPasPlatform;
    SearchPaths: TArray<string>;
    Defines: TArray<string>;
    Namespaces: TArray<string>;
    Aliases: TArray<TPasUnitAlias>;
    Pins: TDictionary<string, string>;   // unit name lower -> file
    ProjectDir: string;
    Roots: TArray<string>;
    Proj: TPasSemaProject;
    Nav: TPasNavigator;
    Stamps: TDictionary<string, TMcpFileStamp>;   // own file (lower) -> stamp
    Paths: TDictionary<string, string>;           // own file (lower) -> path
    OwnModels: Integer;
    LastBuildMs: Int64;
    Builds: Integer;
    ModuleRuns: Integer;
    constructor Create;
    destructor Destroy; override;
    function MemberNames(const AWorkspace: TObject): string;
  end;

  TMcpWorkspace = class
  private
    FProjectFile: string;
    FRoot: string;
    FStudioWanted: string;
    FStudio: TMcpStudio;
    FPlatformOverride: string;
    FConfig: string;
    FPolicy: TMcpGroupPolicy;
    FMembers: TArray<TMcpMember>;
    FMissing: TArray<string>;
    FAnalyses: TObjectList<TMcpAnalysis>;
    FLibDirs: TArray<string>;
    FConfigStamps: TDictionary<string, TMcpFileStamp>;
    FListed: TDictionary<string, Boolean>;   // every member's files, lower
    FOwner: TDictionary<string, Integer>;    // own file, lower -> analysis
    FChanged: TList<string>;                 // see ChangedFiles
    FChangedSeen: TDictionary<string, Boolean>;
    // Own form files and the own unit directories, for the note: a form saved
    // in a designer or by another session changes no Pascal file, and PasTree
    // re-reads it silently. See FormChanges.
    FFormStamps: TDictionary<string, TMcpFileStamp>;   // form file (lower)
    FFormPaths: TDictionary<string, string>;
    FDirStamps: TDictionary<string, TMcpFileStamp>;    // unit dir (lower)
    FDirUnits: TDictionary<string, TArray<string>>;    // unit dir -> own units
    FReady: TEvent;
    FLock: TCriticalSection;
    FState: string;
    FLoadError: string;
    FLoadMs: Int64;
    procedure SetState(const AText: string);
    procedure LoadMembers;
    procedure AssignAnalyses;
    procedure BuildAnalysis(AAnalysis: TMcpAnalysis; ADonor: TPasSemaProject);
    procedure RecordStamps(AAnalysis: TMcpAnalysis);
    // After a module run: stamps the own files it took in that have none yet
    // - a unit a changed uses clause added, an include a changed unit now
    // pulls in - and returns them. Unstamped, their edits and their deletion
    // would never be seen (RecordStamps runs only after a full build).
    function StampNewcomers(AAnalysis: TMcpAnalysis): TArray<string>;
    procedure RecordFormStamps;
    function FormChanges: string;
    procedure RebuildAnalysis(AAnalysis: TMcpAnalysis; const AWhy: string);
    function ChangedConfigFiles: TArray<string>;
    procedure ClearAnalyses;
    procedure RebuildOwners;
  public
    constructor Create(const AProjectFile, AStudio, APlatform, AConfig: string;
      APolicy: TMcpGroupPolicy);
    destructor Destroy; override;
    // Reads the group and analyzes it. Never raises: a failure lands in
    // LoadError and Ready is set either way, so no caller waits forever.
    procedure Load;
    function WaitReady(ATimeoutMs: Cardinal): Boolean;
    function IsReady: Boolean;
    function State: string;
    property LoadError: string read FLoadError;
    // Re-analyzes whatever changed on disk since the last look. AReport says
    // what was done and NAMES the files ('' = nothing had changed): a file
    // the agent did not edit is someone else's edit, and the only sign of it.
    procedure EnsureFresh(out AReport: string);
    // The files EnsureFresh found changed on disk since the load, in the order
    // it met them: this session's edits (and the developer's). `compile`
    // builds the members they reach, and on a member's first build lists the
    // warnings in them - there is no earlier build to tell new from old.
    function ChangedFiles: TArray<string>;
    // A file of the group itself - under the group directory, or listed by a
    // member - as opposed to a library unit the closure pulled in.
    function IsOwnFile(const APath: string): Boolean;
    // The analysis whose diagnostics speak for an own file: the one that
    // lists it (the primary member's first), else the first that holds it -
    // a unit analyzed under two configurations reports two sets of errors,
    // and only its own project's are the ones a build would show. -1 = none.
    function OwnerAnalysis(const APath: string): Integer;
    // The units the analyses hold, each once, and how many are own files.
    function IndexedUnitCount(out AOwn: Integer): Integer;
    // What the index is, for an answer that found nothing in it:
    // `pastree-mcp.dproj`, `the 9 projects of Foo.groupproj`.
    function IndexedProjects: string;
    // The Pascal sources (.pas .dpr .dpk .inc) no analysis holds, under the
    // group directory (every level, but .git and the IDE's __history and
    // __recovery) and in the members' own search path directories. The index
    // is the projects' closure, not the directory: a unit nothing uses is
    // invisible to every tool, and "no declaration matches" alone does not
    // say that the name may be declared in one.
    function UnindexedSources: TArray<string>;
    // APath relative to Root when it lies under it, else APath unchanged.
    function RelPath(const APath: string): string;
    // AFile as the user wrote it (relative to Root, or absolute) -> full path.
    function FullPath(const AFile: string): string;
    function StatusText: string;
    property Root: string read FRoot;
    property ProjectFile: string read FProjectFile;
    property Studio: TMcpStudio read FStudio;
    property Members: TArray<TMcpMember> read FMembers;
    property Analyses: TObjectList<TMcpAnalysis> read FAnalyses;
  end;

function StampOf(const APath: string; out AStamp: TMcpFileStamp): Boolean;

implementation

uses
  System.IOUtils,
  System.StrUtils,
  System.Math,
  System.Diagnostics,
  System.Generics.Defaults,
  Winapi.Windows,
  PasTree.Types,
  PasMcp.Log,
  PasMcp.GroupProj;

function StampOf(const APath: string; out AStamp: TMcpFileStamp): Boolean;
var
  LData: TWin32FileAttributeData;
  LSys: TSystemTime;
begin
  AStamp := Default(TMcpFileStamp);
  Result := GetFileAttributesEx(PChar(APath), GetFileExInfoStandard, @LData);
  if not Result then
    Exit;
  AStamp.Size := Int64(LData.nFileSizeHigh) shl 32 or LData.nFileSizeLow;
  if FileTimeToSystemTime(LData.ftLastWriteTime, LSys) then
    AStamp.Time := SystemTimeToDateTime(LSys);
end;

function SameStamp(const A, B: TMcpFileStamp): Boolean;
begin
  Result := (A.Size = B.Size) and SameValue(A.Time, B.Time, 1 / 86400000);
end;

// Case-insensitive, order-keeping union.
procedure AddUnique(var AList: TArray<string>; const AItems: TArray<string>);
var
  LFound: Boolean;
begin
  for var LItem in AItems do
  begin
    if LItem = '' then
      Continue;
    LFound := False;
    for var LHave in AList do
      if SameText(LHave, LItem) then
      begin
        LFound := True;
        Break;
      end;
    if not LFound then
      AList := AList + [LItem];
  end;
end;

function SortedLower(const AItems: TArray<string>): string;
var
  LList: TStringList;
begin
  LList := TStringList.Create;
  try
    for var LItem in AItems do
      LList.Add(LowerCase(Trim(LItem)));
    LList.Sort;
    Result := LList.CommaText;
  finally
    LList.Free;
  end;
end;

{ TMcpAnalysis }

constructor TMcpAnalysis.Create;
begin
  inherited Create;
  Pins := TDictionary<string, string>.Create;
  Stamps := TDictionary<string, TMcpFileStamp>.Create;
  Paths := TDictionary<string, string>.Create;
end;

destructor TMcpAnalysis.Destroy;
begin
  Nav.Free;
  Proj.Free;
  Paths.Free;
  Stamps.Free;
  Pins.Free;
  inherited;
end;

function TMcpAnalysis.MemberNames(const AWorkspace: TObject): string;
var
  LWs: TMcpWorkspace;
begin
  LWs := TMcpWorkspace(AWorkspace);
  Result := '';
  for var LIdx in Members do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + LWs.FMembers[LIdx].Name;
  end;
end;

{ TMcpWorkspace }

constructor TMcpWorkspace.Create(const AProjectFile, AStudio, APlatform,
  AConfig: string; APolicy: TMcpGroupPolicy);
begin
  inherited Create;
  FProjectFile := TPath.GetFullPath(AProjectFile);
  FRoot := TPath.GetDirectoryName(FProjectFile);
  FStudioWanted := AStudio;
  FPlatformOverride := APlatform;
  FConfig := AConfig;
  FPolicy := APolicy;
  FAnalyses := TObjectList<TMcpAnalysis>.Create(True);
  FConfigStamps := TDictionary<string, TMcpFileStamp>.Create;
  FListed := TDictionary<string, Boolean>.Create;
  FOwner := TDictionary<string, Integer>.Create;
  FChanged := TList<string>.Create;
  FChangedSeen := TDictionary<string, Boolean>.Create;
  FFormStamps := TDictionary<string, TMcpFileStamp>.Create;
  FFormPaths := TDictionary<string, string>.Create;
  FDirStamps := TDictionary<string, TMcpFileStamp>.Create;
  FDirUnits := TDictionary<string, TArray<string>>.Create;
  FReady := TEvent.Create(nil, True, False, '');
  FLock := TCriticalSection.Create;
  FState := 'not started';
end;

destructor TMcpWorkspace.Destroy;
begin
  FAnalyses.Free;
  FConfigStamps.Free;
  FListed.Free;
  FOwner.Free;
  FChanged.Free;
  FChangedSeen.Free;
  FFormStamps.Free;
  FFormPaths.Free;
  FDirStamps.Free;
  FDirUnits.Free;
  FReady.Free;
  FLock.Free;
  inherited;
end;

function TMcpWorkspace.ChangedFiles: TArray<string>;
begin
  Result := FChanged.ToArray;
end;

procedure TMcpWorkspace.SetState(const AText: string);
begin
  FLock.Enter;
  try
    FState := AText;
  finally
    FLock.Leave;
  end;
end;

function TMcpWorkspace.State: string;
begin
  FLock.Enter;
  try
    Result := FState;
  finally
    FLock.Leave;
  end;
end;

function TMcpWorkspace.WaitReady(ATimeoutMs: Cardinal): Boolean;
begin
  Result := FReady.WaitFor(ATimeoutMs) = wrSignaled;
end;

function TMcpWorkspace.IsReady: Boolean;
begin
  Result := WaitReady(0);
end;

function TMcpWorkspace.RelPath(const APath: string): string;
var
  LRoot: string;
begin
  LRoot := IncludeTrailingPathDelimiter(FRoot);
  if StartsText(LRoot, APath) then
    Result := Copy(APath, Length(LRoot) + 1, MaxInt)
  else
    Result := APath;
end;

function TMcpWorkspace.FullPath(const AFile: string): string;
begin
  if TPath.IsPathRooted(AFile) then
    Result := TPath.GetFullPath(AFile)
  else
    Result := TPath.GetFullPath(TPath.Combine(FRoot, AFile));
end;

function TMcpWorkspace.IsOwnFile(const APath: string): Boolean;
begin
  Result := StartsText(IncludeTrailingPathDelimiter(FRoot), APath) or
    FListed.ContainsKey(LowerCase(APath));
end;

function TMcpWorkspace.IndexedUnitCount(out AOwn: Integer): Integer;
var
  LSeen: TDictionary<string, Boolean>;
  LFile: string;
begin
  AOwn := 0;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for var LA in FAnalyses do
      if LA.Proj <> nil then
        for var LMid := 0 to LA.Proj.ModelCount - 1 do
        begin
          LFile := LA.Proj.ModelFile(LMid);
          if LSeen.TryAdd(LowerCase(LFile), True) and IsOwnFile(LFile) then
            Inc(AOwn);
        end;
    Result := LSeen.Count;
  finally
    LSeen.Free;
  end;
end;

function TMcpWorkspace.IndexedProjects: string;
begin
  if Length(FMembers) = 1 then
    Result := TPath.GetFileName(FMembers[0].ProjectFile)
  else
    Result := Format('the %d projects of %s', [Length(FMembers),
      TPath.GetFileName(FProjectFile)]);
end;

function TMcpWorkspace.UnindexedSources: TArray<string>;
var
  LIndexed, LDone: TDictionary<string, Boolean>;
  LList: TList<string>;
  LFull: string;

  function IsSource(const AName: string): Boolean;
  var
    LExt: string;
  begin
    LExt := LowerCase(TPath.GetExtension(AName));
    Result := (LExt = '.pas') or (LExt = '.dpr') or (LExt = '.dpk') or
      (LExt = '.inc');
  end;

  procedure Walk(const ADir: string; ADeep: Boolean);
  var
    LSr: TSearchRec;
    LPath: string;
  begin
    if not LDone.TryAdd(LowerCase(ExcludeTrailingPathDelimiter(ADir)), True) then
      Exit;
    if FindFirst(TPath.Combine(ADir, '*'), faAnyFile, LSr) <> 0 then
      Exit;
    try
      repeat
        if (LSr.Name = '.') or (LSr.Name = '..') then
          Continue;
        LPath := TPath.Combine(ADir, LSr.Name);
        if (LSr.Attr and faDirectory) <> 0 then
        begin
          // A junction could lead back up; the IDE's backups repeat every
          // unit under another extension anyway.
          if ADeep and ((LSr.Attr and FILE_ATTRIBUTE_REPARSE_POINT) = 0) and
             not StartsStr('.', LSr.Name) and
             not SameText(LSr.Name, '__history') and
             not SameText(LSr.Name, '__recovery') then
            Walk(LPath, True);
        end
        else if IsSource(LSr.Name) and
          not LIndexed.ContainsKey(LowerCase(LPath)) then
          LList.Add(LPath);
      until FindNext(LSr) <> 0;
    finally
      System.SysUtils.FindClose(LSr);   // not Winapi.Windows' FindClose(THandle)
    end;
  end;

begin
  LIndexed := TDictionary<string, Boolean>.Create;
  LDone := TDictionary<string, Boolean>.Create;
  LList := TList<string>.Create;
  try
    for var LA in FAnalyses do
      if LA.Proj <> nil then
        for var LMid := 0 to LA.Proj.ModelCount - 1 do
        begin
          LIndexed.AddOrSetValue(LowerCase(LA.Proj.ModelFile(LMid)), True);
          // Its includes too: a demoted model keeps its file names.
          for var LFile in LA.Proj.Model(LMid).Tree.Source.FileNames do
            if LFile <> '' then
              LIndexed.AddOrSetValue(LowerCase(LFile), True);
        end;
    Walk(FRoot, True);
    // A search path directory holds units by name, not by level. Its path
    // may be written `..\lib`: the index holds full paths.
    for var LMem in FMembers do
      for var LDir in LMem.SearchPaths do
      begin
        if Trim(LDir) = '' then
          Continue;
        try
          LFull := TPath.GetFullPath(Trim(LDir));
        except
          Continue;   // a macro left unexpanded, a character a path cannot hold
        end;
        if TDirectory.Exists(LFull) and not StartsText(
           IncludeTrailingPathDelimiter(FRoot), IncludeTrailingPathDelimiter(LFull))
        then
          Walk(LFull, False);
      end;
    Result := LList.ToArray;
  finally
    LList.Free;
    LDone.Free;
    LIndexed.Free;
  end;
end;

procedure TMcpWorkspace.LoadMembers;
var
  LFiles, LMissing: TArray<string>;
  LExt: string;
  LM: TMcpMember;
  LD: TPasDProj;
  LStamp: TMcpFileStamp;
begin
  FMembers := nil;
  FMissing := nil;
  FConfigStamps.Clear;
  LExt := LowerCase(TPath.GetExtension(FProjectFile));
  if LExt = '.groupproj' then
  begin
    if not ReadGroupProj(FProjectFile, LFiles, LMissing) then
      raise Exception.Create('cannot read project group ' + FProjectFile);
    FMissing := LMissing;
  end
  else if (LExt = '.dproj') or (LExt = '.dpr') or (LExt = '.dpk') then
    LFiles := [FProjectFile]
  else
    raise Exception.Create('not a .groupproj, .dproj, .dpr or .dpk: ' +
      FProjectFile);
  // By path as written, not lower-cased: a changed one is named in a report.
  if StampOf(FProjectFile, LStamp) then
    FConfigStamps.AddOrSetValue(FProjectFile, LStamp);

  for var LFile in LFiles do
  begin
    LM := Default(TMcpMember);
    LM.ProjectFile := LFile;
    LM.Name := TPath.GetFileNameWithoutExtension(LFile);
    LM.Analysis := -1;
    if SameText(TPath.GetExtension(LFile), '.dproj') then
    begin
      LD := TPasDProj.Create;
      try
        if LD.Load(LFile, FPlatformOverride, FConfig) and
           TFile.Exists(LD.MainSource) then
        begin
          LM.MainSource := LD.MainSource;
          LM.Platform := LD.Platform;
          LM.Config := LD.Config;
          LM.SearchPaths := LD.SearchPaths;
          LM.Defines := LD.Defines;
          LM.Namespaces := LD.Namespaces;
          LM.Aliases := LD.UnitAliases;
          for var LF in LD.Files do
            if SameText(TPath.GetExtension(LF), '.pas') then
              LM.Files := LM.Files + [LF];
        end
        else
          LM.Error := 'the .dproj did not load or names no existing main source';
      finally
        LD.Free;
      end;
      if StampOf(LFile, LStamp) then
        FConfigStamps.AddOrSetValue(LFile, LStamp);
    end
    else
    begin
      // A bare .dpr/.dpk: no MSBuild properties, the IDE defaults.
      LM.MainSource := LFile;
      if not TryParsePlatformName(FPlatformOverride, LM.Platform) then
        LM.Platform := pfWin32;
    end;
    if LM.Error = '' then
    begin
      if Length(LM.Namespaces) = 0 then
        LM.Namespaces := PasDefaultNamespaces(LM.Platform)
      else
        AddUnique(LM.Namespaces, PasDefaultNamespaces(LM.Platform));
    end;
    FMembers := FMembers + [LM];
  end;
  FListed.Clear;
  for var LMem in FMembers do
  begin
    for var LF in LMem.Files do
      FListed.AddOrSetValue(LowerCase(LF), True);
    if LMem.MainSource <> '' then
      FListed.AddOrSetValue(LowerCase(LMem.MainSource), True);
  end;
end;

procedure TMcpWorkspace.AssignAnalyses;
var
  LOrder: TArray<Integer>;
  LPrimary, LBest: Integer;
  LKeys: TDictionary<Integer, string>;
  LA: TMcpAnalysis;
  LFits: Boolean;
  LUnit, LHave, LKey: string;

  function KeyOf(const AM: TMcpMember): string;
  var
    LAl: string;
  begin
    Result := PlatformName(AM.Platform);
    if FPolicy = gpStrict then
    begin
      LAl := '';
      for var LA2 in AM.Aliases do
        LAl := LAl + LowerCase(LA2.Alias + '=' + LA2.UnitName) + ';';
      Result := Result + '|' + SortedLower(AM.Defines) + '|' +
        LowerCase(string.Join(';', AM.Namespaces)) + '|' + LAl;
    end;
  end;

begin
  FAnalyses.Clear;
  // The primary member - most listed files - is placed first, so an analysis
  // it lands in takes its configuration from it.
  LPrimary := -1;
  LBest := -1;
  for var LIdx := 0 to High(FMembers) do
    if (FMembers[LIdx].Error = '') and (Length(FMembers[LIdx].Files) > LBest)
    then
    begin
      LBest := Length(FMembers[LIdx].Files);
      LPrimary := LIdx;
    end;
  if LPrimary < 0 then
    Exit;
  // Largest first, not file order: an analysis takes its defines from the
  // member that CREATES it, and on the client group file order let a
  // one-file helper project create the Win64 analysis - the server project
  // then ran under the helper's defines, took the client-only $IFDEF branches
  // and reported 170 unresolved units and 8000 errors that its own build
  // does not have.
  for var LIdx := 0 to High(FMembers) do
    if FMembers[LIdx].Error = '' then
      LOrder := LOrder + [LIdx];
  TArray.Sort<Integer>(LOrder, TComparer<Integer>.Construct(
    function(const L, R: Integer): Integer
    begin
      Result := Length(FMembers[R].Files) - Length(FMembers[L].Files);
      if Result = 0 then
        Result := L - R;
    end));

  LKeys := TDictionary<Integer, string>.Create;
  try
    for var LIdx in LOrder do
    begin
      LKey := KeyOf(FMembers[LIdx]);
      LA := nil;
      for var LCand in FAnalyses do
      begin
        if LKeys[LCand.Index] <> LKey then
          Continue;
        LFits := True;
        for var LF in FMembers[LIdx].Files do
        begin
          LUnit := LowerCase(TPath.GetFileNameWithoutExtension(LF));
          if LCand.Pins.TryGetValue(LUnit, LHave) and not SameText(LHave, LF)
          then
          begin
            Log('  %s lists %s, but %s is already pinned in analysis %d - '
              + 'it gets an analysis of its own', [FMembers[LIdx].Name, LF,
              LHave, LCand.Index]);
            LFits := False;
            Break;
          end;
        end;
        if LFits then
        begin
          LA := LCand;
          Break;
        end;
      end;
      if LA = nil then
      begin
        LA := TMcpAnalysis.Create;
        LA.Index := FAnalyses.Count;
        LA.Platform := FMembers[LIdx].Platform;
        LA.Defines := FMembers[LIdx].Defines;
        LA.ProjectDir := TPath.GetDirectoryName(FMembers[LIdx].ProjectFile);
        FAnalyses.Add(LA);
        LKeys.Add(LA.Index, LKey);
      end
      else if SortedLower(LA.Defines) <> SortedLower(FMembers[LIdx].Defines)
      then
        Log('  %s shares analysis %d but its defines differ: its own [%s], '
          + 'analyzed with [%s]', [FMembers[LIdx].Name, LA.Index,
          string.Join(';', FMembers[LIdx].Defines), string.Join(';',
          LA.Defines)]);
      LA.Members := LA.Members + [LIdx];
      FMembers[LIdx].Analysis := LA.Index;
      LA.Roots := LA.Roots + [FMembers[LIdx].MainSource];
      AddUnique(LA.Namespaces, FMembers[LIdx].Namespaces);
      for var LF in FMembers[LIdx].Files do
        LA.Pins.AddOrSetValue(LowerCase(TPath.GetFileNameWithoutExtension(LF)),
          LF);
    end;

    // Search paths: every member's directory, then every member's own paths
    // (the analysis' first member first), then the installed library.
    for LA in FAnalyses do
    begin
      LA.SearchPaths := nil;
      for var LIdx in LA.Members do
        AddUnique(LA.SearchPaths,
          [TPath.GetDirectoryName(FMembers[LIdx].ProjectFile)]);
      for var LIdx in LA.Members do
        AddUnique(LA.SearchPaths, FMembers[LIdx].SearchPaths);
      AddUnique(LA.SearchPaths, FStudio.LibraryPaths(LA.Platform));
      // Aliases: the defaults, then every member's, the analysis' first member
      // LAST - AddUnitAlias is last-wins, so it gets the final word.
      LA.Aliases := nil;
      for var LDef in PasDefaultUnitAliases(LA.Platform) do
      begin
        var LAl: TPasUnitAlias;
        LAl.Alias := LDef.Alias;
        LAl.UnitName := LDef.UnitName;
        LA.Aliases := LA.Aliases + [LAl];
      end;
      for var LI := High(LA.Members) downto 0 do
        LA.Aliases := LA.Aliases + FMembers[LA.Members[LI]].Aliases;
    end;
  finally
    LKeys.Free;
  end;
end;

procedure TMcpWorkspace.RecordStamps(AAnalysis: TMcpAnalysis);
var
  LM: TPasSemaModel;
  LStamp: TMcpFileStamp;
  LFile: string;
begin
  AAnalysis.Stamps.Clear;
  AAnalysis.Paths.Clear;
  AAnalysis.OwnModels := 0;
  for var LMid := 0 to AAnalysis.Proj.ModelCount - 1 do
  begin
    if not IsOwnFile(AAnalysis.Proj.ModelFile(LMid)) then
      Continue;
    Inc(AAnalysis.OwnModels);
    LM := AAnalysis.Proj.Model(LMid);
    // The main file and every include it pulled in.
    for var LFi := 0 to High(LM.Tree.Source.FileNames) do
    begin
      LFile := LM.Tree.Source.FileNames[LFi];
      if (LFile <> '') and StampOf(LFile, LStamp) then
      begin
        AAnalysis.Stamps.AddOrSetValue(LowerCase(LFile), LStamp);
        AAnalysis.Paths.AddOrSetValue(LowerCase(LFile), LFile);
      end;
    end;
  end;
end;

function TMcpWorkspace.StampNewcomers(AAnalysis: TMcpAnalysis): TArray<string>;
var
  LM: TPasSemaModel;
  LStamp: TMcpFileStamp;
  LFile: string;
begin
  Result := nil;
  for var LMid := 0 to AAnalysis.Proj.ModelCount - 1 do
  begin
    if not IsOwnFile(AAnalysis.Proj.ModelFile(LMid)) then
      Continue;
    LM := AAnalysis.Proj.Model(LMid);
    for var LFi := 0 to High(LM.Tree.Source.FileNames) do
    begin
      LFile := LM.Tree.Source.FileNames[LFi];
      if (LFile = '') or AAnalysis.Stamps.ContainsKey(LowerCase(LFile)) or
         not StampOf(LFile, LStamp) then
        Continue;
      AAnalysis.Stamps.Add(LowerCase(LFile), LStamp);
      AAnalysis.Paths.AddOrSetValue(LowerCase(LFile), LFile);
      if LFi = 0 then
        Inc(AAnalysis.OwnModels);
      Result := Result + [LFile];
    end;
  end;
end;

// A report's list of files: relative, sorted, the first MAX_NAMED of them
// named and the rest counted.
function NamedFiles(AWs: TMcpWorkspace; const AFiles: TArray<string>): string;
const
  MAX_NAMED = 8;
var
  LNames: TArray<string>;
begin
  LNames := nil;
  for var LFile in AFiles do
    LNames := LNames + [AWs.RelPath(LFile)];
  TArray.Sort<string>(LNames, TComparer<string>.Construct(
    function(const L, R: string): Integer
    begin
      Result := CompareText(L, R);
    end));
  Result := string.Join(', ', Copy(LNames, 0, MAX_NAMED));
  if Length(LNames) > MAX_NAMED then
    Result := Result + Format(' and %d more', [Length(LNames) - MAX_NAMED]);
end;

// The form file beside AUnit - .dfm, else .fmx - with its stamp; False when
// there is none.
function FormFileOf(const AUnit: string; out AFile: string;
  out AStamp: TMcpFileStamp): Boolean;
begin
  AFile := ChangeFileExt(AUnit, '.dfm');
  Result := StampOf(AFile, AStamp);
  if not Result then
  begin
    AFile := ChangeFileExt(AUnit, '.fmx');
    Result := StampOf(AFile, AStamp);
  end;
end;

procedure TMcpWorkspace.RecordFormStamps;
var
  LSeen: TDictionary<string, Boolean>;
  LFile, LDir, LForm: string;
  LUnits: TArray<string>;
  LStamp: TMcpFileStamp;
begin
  FFormStamps.Clear;
  FFormPaths.Clear;
  FDirStamps.Clear;
  FDirUnits.Clear;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for var LA in FAnalyses do
      if LA.Proj <> nil then
        for var LMid := 0 to LA.Proj.ModelCount - 1 do
        begin
          LFile := LA.Proj.ModelFile(LMid);
          if (LFile = '') or not IsOwnFile(LFile) or
             not LSeen.TryAdd(LowerCase(LFile), True) then
            Continue;
          LDir := LowerCase(ExtractFileDir(LFile));
          if not FDirUnits.TryGetValue(LDir, LUnits) then
          begin
            LUnits := nil;
            if StampOf(ExtractFileDir(LFile), LStamp) then
              FDirStamps.AddOrSetValue(LDir, LStamp);
          end;
          FDirUnits.AddOrSetValue(LDir, LUnits + [LFile]);
          if FormFileOf(LFile, LForm, LStamp) then
          begin
            FFormStamps.AddOrSetValue(LowerCase(LForm), LStamp);
            FFormPaths.AddOrSetValue(LowerCase(LForm), LForm);
          end;
        end;
  finally
    LSeen.Free;
  end;
end;

// The own form files changed, created or deleted since the last look, as
// clauses of the note ('' = none), the stamps moved on. A new one is found
// through its directory, whose write time moves when a file appears in it -
// one call per directory rather than two probes per unit on every call.
function TMcpWorkspace.FormChanges: string;
var
  LChanged, LAdded, LGone: TArray<string>;
  LStamp: TMcpFileStamp;
  LForm: string;
  LDirs: TArray<string>;
begin
  LChanged := nil;
  LAdded := nil;
  LGone := nil;
  for var LPair in FFormStamps do
    if not StampOf(FFormPaths[LPair.Key], LStamp) then
      LGone := LGone + [FFormPaths[LPair.Key]]
    else if not SameStamp(LStamp, LPair.Value) then
      LChanged := LChanged + [FFormPaths[LPair.Key]];
  for var LFile in LGone do
    FFormStamps.Remove(LowerCase(LFile));
  for var LFile in LChanged do
    if StampOf(LFile, LStamp) then
      FFormStamps[LowerCase(LFile)] := LStamp;
  LDirs := FDirStamps.Keys.ToArray;
  for var LDir in LDirs do
  begin
    if not StampOf(ExtractFileDir(FDirUnits[LDir][0]), LStamp) or
       SameStamp(LStamp, FDirStamps[LDir]) then
      Continue;
    FDirStamps[LDir] := LStamp;
    for var LUnit in FDirUnits[LDir] do
      if FormFileOf(LUnit, LForm, LStamp) and
         FFormStamps.TryAdd(LowerCase(LForm), LStamp) then
      begin
        FFormPaths.AddOrSetValue(LowerCase(LForm), LForm);
        LAdded := LAdded + [LForm];
      end;
  end;
  Result := '';
  if Length(LChanged) > 0 then
    Result := Result + '; form file(s) changed: ' + NamedFiles(Self, LChanged);
  if Length(LAdded) > 0 then
    Result := Result + '; form file(s) added: ' + NamedFiles(Self, LAdded);
  if Length(LGone) > 0 then
    Result := Result + '; form file(s) deleted: ' + NamedFiles(Self, LGone);
  Result := Result.TrimLeft([';', ' ']);
end;

procedure TMcpWorkspace.BuildAnalysis(AAnalysis: TMcpAnalysis;
  ADonor: TPasSemaProject);
var
  LProj: TPasSemaProject;
  LSW: TStopwatch;
  LKeep: TList<string>;
  LLast: Int64;
  LPrefix: string;
begin
  LPrefix := Format('analysis %d (%s)', [AAnalysis.Index,
    AAnalysis.MemberNames(Self)]);
  Log('%s: %s, %d roots, %d search paths, %d defines [%s]', [LPrefix,
    PlatformName(AAnalysis.Platform), Length(AAnalysis.Roots),
    Length(AAnalysis.SearchPaths), Length(AAnalysis.Defines),
    string.Join(';', AAnalysis.Defines)]);
  if FStudio.Found then
    LProj := TPasSemaProject.Create(AAnalysis.Platform, AAnalysis.SearchPaths,
      AAnalysis.Defines, FStudio.CompilerVersion)
  else
    LProj := TPasSemaProject.Create(AAnalysis.Platform, AAnalysis.SearchPaths,
      AAnalysis.Defines);
  try
    LProj.SetNamespaces(AAnalysis.Namespaces);
    for var LAl in AAnalysis.Aliases do
      LProj.AddUnitAlias(LAl.Alias, LAl.UnitName);
    LProj.SetProjectDir(AAnalysis.ProjectDir);
    for var LPin in AAnalysis.Pins.Values do
      LProj.PinUnitFile(LPin);
    // The same switch pastree-lsp turns on: a member after a dot that nothing
    // resolves is E2003 too, and PasTree's corpus runs report zero false ones.
    LProj.ReportUnresolvedMembers := True;
    if (ADonor <> nil) and not LProj.AdoptParseDonor(ADonor) then
      Log('%s: parse donor refused (configuration changed)', [LPrefix]);
    LSW := TStopwatch.StartNew;
    LLast := 0;
    LProj.AnalyzeStaged(AAnalysis.Roots, [], nil,
      procedure(AP: TPasStagedProgress)
      begin
        SetState(Format('%s: %s, %d of %d units', [LPrefix, AP.Phase,
          AP.FullDone, AP.Total]));
        if LSW.ElapsedMilliseconds - LLast >= 5000 then
        begin
          LLast := LSW.ElapsedMilliseconds;
          Log('%s: %s %d/%d', [LPrefix, AP.Phase, AP.FullDone, AP.Total]);
        end;
      end);
    AAnalysis.LastBuildMs := LSW.ElapsedMilliseconds;
    Inc(AAnalysis.Builds);
  except
    LProj.Free;
    raise;
  end;
  FreeAndNil(AAnalysis.Nav);
  FreeAndNil(AAnalysis.Proj);
  AAnalysis.Proj := LProj;
  RecordStamps(AAnalysis);
  LKeep := TList<string>.Create;
  try
    for var LMid := 0 to LProj.ModelCount - 1 do
      if IsOwnFile(LProj.ModelFile(LMid)) then
        LKeep.Add(LProj.ModelFile(LMid));
    LProj.DemoteText(LKeep.ToArray);
  finally
    LKeep.Free;
  end;
  AAnalysis.Nav := TPasNavigator.Create(LProj);
  AAnalysis.Nav.LibraryPaths := FLibDirs;
  Log('%s: %d units (%d own) in %.1f s, %s held; stages %s', [LPrefix,
    LProj.ModelCount, AAnalysis.OwnModels, AAnalysis.LastBuildMs / 1000,
    MemoryText(AllocatedBytes), LProj.StageTimings]);
  if Length(LProj.LoadFailures) > 0 then
    for var LFail in LProj.LoadFailures do
      Log('%s: INTERNAL parse failure (analyzer defect): %s', [LPrefix, LFail]);
end;

procedure TMcpWorkspace.ClearAnalyses;
begin
  FAnalyses.Clear;
  FOwner.Clear;
end;

procedure TMcpWorkspace.RebuildOwners;
var
  LFile: string;
begin
  FOwner.Clear;
  // Listed files first, analyses in index order - analysis 0 holds the
  // primary member - then whatever else each analysis reached.
  for var LA in FAnalyses do
    for var LPin in LA.Pins.Values do
      FOwner.TryAdd(LowerCase(LPin), LA.Index);
  for var LA in FAnalyses do
    for var LMain in LA.Roots do
      FOwner.TryAdd(LowerCase(LMain), LA.Index);
  for var LA in FAnalyses do
    if LA.Proj <> nil then
      for var LMid := 0 to LA.Proj.ModelCount - 1 do
      begin
        LFile := LA.Proj.ModelFile(LMid);
        if IsOwnFile(LFile) then
          FOwner.TryAdd(LowerCase(LFile), LA.Index);
      end;
end;

function TMcpWorkspace.OwnerAnalysis(const APath: string): Integer;
begin
  if not FOwner.TryGetValue(LowerCase(APath), Result) then
    Result := -1;
end;

procedure TMcpWorkspace.Load;
var
  LSW: TStopwatch;
begin
  LSW := TStopwatch.StartNew;
  FLoadError := '';
  try
    try
      SetState('reading the project');
      FStudio := FindStudio(FStudioWanted);
      if FStudio.Found then
        Log('RAD Studio %s at %s (dcc %.1f)', [FStudio.Version, FStudio.Root,
          FStudio.CompilerVersion])
      else
        Log('no RAD Studio installation found - RTL/VCL and the component '
          + 'libraries will not resolve');
      LoadMembers;
      for var LMiss in FMissing do
        Log('group member missing on disk: %s', [LMiss]);
      AssignAnalyses;
      FLibDirs := nil;
      if FStudio.Found then
        FLibDirs := [FStudio.Root];
      for var LA in FAnalyses do
        AddUnique(FLibDirs, FStudio.LibraryPaths(LA.Platform));
      for var LM in FMembers do
        if LM.Error <> '' then
          Log('member %s skipped: %s', [LM.Name, LM.Error])
        else
          Log('member %s: %s %s, %d files, analysis %d', [LM.Name,
            PlatformName(LM.Platform), LM.Config, Length(LM.Files),
            LM.Analysis]);
      if FAnalyses.Count = 0 then
        raise Exception.Create('no loadable project in ' + FProjectFile);
      for var LA in FAnalyses do
        BuildAnalysis(LA, nil);
      RebuildOwners;
      RecordFormStamps;
      FLoadMs := LSW.ElapsedMilliseconds;
      SetState('ready');
      Log('ready in %.1f s', [FLoadMs / 1000]);
    except
      on E: Exception do
      begin
        FLoadError := E.ClassName + ': ' + E.Message;
        SetState('failed: ' + FLoadError);
        Log('load failed: %s', [FLoadError]);
      end;
    end;
  finally
    FReady.SetEvent;
  end;
end;

function TMcpWorkspace.ChangedConfigFiles: TArray<string>;
var
  LStamp: TMcpFileStamp;
begin
  Result := nil;
  for var LPair in FConfigStamps do
    if not StampOf(LPair.Key, LStamp) or not SameStamp(LStamp, LPair.Value) then
      Result := Result + [LPair.Key];
end;

procedure TMcpWorkspace.RebuildAnalysis(AAnalysis: TMcpAnalysis;
  const AWhy: string);
var
  LOld: TPasSemaProject;
begin
  Log('analysis %d: full rebuild - %s', [AAnalysis.Index, AWhy]);
  // The old project donates every unchanged parse; it must outlive the run.
  LOld := AAnalysis.Proj;
  FreeAndNil(AAnalysis.Nav);
  AAnalysis.Proj := nil;
  try
    BuildAnalysis(AAnalysis, LOld);
  finally
    LOld.Free;
  end;
  RebuildOwners;
  RecordFormStamps;
end;

procedure TMcpWorkspace.EnsureFresh(out AReport: string);
var
  LChanged, LGone: TList<string>;
  LAllChanged, LAllGone, LAllAdded: TArray<string>;   // over the analyses, each once
  LAllSeen: TDictionary<string, Boolean>;
  LBefore: TDictionary<string, TMcpFileStamp>;
  LForms: string;
  LAdded: TArray<string>;
  LStamp: TMcpFileStamp;
  LNeedRebuild: string;
  LConfig: TArray<string>;
  LMid: Integer;
  LSW: TStopwatch;
  LOk, LRebuilt: Boolean;
  LTotalMs: Int64;
begin
  AReport := '';
  if (FLoadError <> '') or (FAnalyses.Count = 0) then
    Exit;
  LConfig := ChangedConfigFiles;
  if Length(LConfig) > 0 then
  begin
    Log('project file(s) changed (%s) - reloading the workspace',
      [NamedFiles(Self, LConfig)]);
    ClearAnalyses;
    FReady.ResetEvent;
    Load;
    AReport := Format('project file(s) changed: %s; the workspace was reloaded',
      [NamedFiles(Self, LConfig)]);
    Exit;
  end;
  // First: a rebuild below records the form stamps afresh.
  LForms := FormChanges;
  LAllChanged := nil;
  LAllGone := nil;
  LAllAdded := nil;
  LRebuilt := False;
  LTotalMs := 0;
  LChanged := TList<string>.Create;
  LGone := TList<string>.Create;
  LAllSeen := TDictionary<string, Boolean>.Create;
  try
    for var LA in FAnalyses do
    begin
      LChanged.Clear;
      LGone.Clear;
      for var LPair in LA.Stamps do
        if not StampOf(LA.Paths[LPair.Key], LStamp) then
          LGone.Add(LA.Paths[LPair.Key])
        else if not SameStamp(LStamp, LPair.Value) then
          LChanged.Add(LA.Paths[LPair.Key]);
      if (LGone.Count = 0) and (LChanged.Count = 0) then
        Continue;
      for var LFile in LChanged do
      begin
        if not FChangedSeen.ContainsKey(LowerCase(LFile)) then
        begin
          FChangedSeen.Add(LowerCase(LFile), True);
          FChanged.Add(LFile);
        end;
        // A unit shared by several analyses changed in each of them.
        if LAllSeen.TryAdd(LowerCase(LFile), True) then
          LAllChanged := LAllChanged + [LFile];
      end;
      for var LFile in LGone do
        if LAllSeen.TryAdd(LowerCase(LFile), True) then
          LAllGone := LAllGone + [LFile];
      LSW := TStopwatch.StartNew;
      LNeedRebuild := '';
      if LGone.Count > 0 then
        LNeedRebuild := 'deleted: ' + NamedFiles(Self, LGone.ToArray);
      if LNeedRebuild = '' then
        for var LFile in LChanged do
        begin
          LMid := LA.Proj.ModelIdOf(LFile);
          if LMid < 0 then
          begin
            LNeedRebuild := 'include file changed: ' + RelPath(LFile);
            Break;
          end;
          try
            LOk := LA.Proj.AnalyzeModuleOnly(LFile);
          except
            on E: Exception do
            begin
              Log('analysis %d: module run on %s raised %s: %s', [LA.Index,
                RelPath(LFile), E.ClassName, E.Message]);
              LOk := False;
            end
            else
              LOk := False;
          end;
          if not LOk or LA.Proj.NeedsFullRebuild then
          begin
            LNeedRebuild := 'the module path refused ' + RelPath(LFile);
            Break;
          end;
          Inc(LA.ModuleRuns);
          if StampOf(LFile, LStamp) then
            LA.Stamps.AddOrSetValue(LowerCase(LFile), LStamp);
        end;
      LAdded := nil;
      if LNeedRebuild <> '' then
      begin
        LBefore := TDictionary<string, TMcpFileStamp>.Create(LA.Stamps);
        try
          RebuildAnalysis(LA, LNeedRebuild);
          for var LKey in LA.Stamps.Keys do
            if not LBefore.ContainsKey(LKey) then
              LAdded := LAdded + [LA.Paths[LKey]];
        finally
          LBefore.Free;
        end;
      end
      else
      begin
        LAdded := StampNewcomers(LA);
        if Length(LAdded) > 0 then
        begin
          RebuildOwners;
          RecordFormStamps;
        end;
        // The models changed under the navigator's per-model caches.
        FreeAndNil(LA.Nav);
        LA.Nav := TPasNavigator.Create(LA.Proj);
        LA.Nav.LibraryPaths := FLibDirs;
      end;
      for var LFile in LAdded do
      begin
        if FChangedSeen.TryAdd(LowerCase(LFile), True) then
          FChanged.Add(LFile);
        if LAllSeen.TryAdd(LowerCase(LFile), True) then
          LAllAdded := LAllAdded + [LFile];
      end;
      Log('analysis %d: %d changed file(s) re-analyzed in %d ms%s: %s',
        [LA.Index, LChanged.Count, LSW.ElapsedMilliseconds,
        IfThen(LNeedRebuild <> '', ' (full rebuild)', ''),
        NamedFiles(Self, LChanged.ToArray)]);
      Inc(LTotalMs, LSW.ElapsedMilliseconds);
      LRebuilt := LRebuilt or (LNeedRebuild <> '');
    end;
  finally
    LAllSeen.Free;
    LGone.Free;
    LChanged.Free;
  end;
  if Length(LAllChanged) > 0 then
    AReport := Format('re-analyzed %d changed file(s)%s in %d ms: %s',
      [Length(LAllChanged), IfThen(LRebuilt, ' (full rebuild)', ''), LTotalMs,
      NamedFiles(Self, LAllChanged)]);
  if Length(LAllGone) > 0 then
  begin
    if AReport = '' then
      AReport := Format('rebuilt in %d ms', [LTotalMs]);
    AReport := AReport + '; deleted: ' + NamedFiles(Self, LAllGone);
  end;
  // A unit another session added shows otherwise only as its user's change.
  if (AReport <> '') and (Length(LAllAdded) > 0) then
    AReport := AReport + '; added: ' + NamedFiles(Self, LAllAdded);
  if LForms <> '' then
    if AReport = '' then
      AReport := LForms
    else
      AReport := AReport + '; ' + LForms;
end;

function TMcpWorkspace.StatusText: string;
var
  LSb: TStringBuilder;
  LMissing: TDictionary<string, Integer>;
  LM: TPasSemaModel;
  LN: Integer;
  LNames: TList<string>;
begin
  LSb := TStringBuilder.Create;
  try
    LSb.AppendLine('project: ' + FProjectFile);
    LSb.AppendLine('paths in results are relative to: ' + FRoot);
    if FStudio.Found then
      LSb.AppendLine(Format('RAD Studio %s (dcc %.1f) at %s', [FStudio.Version,
        FStudio.CompilerVersion, FStudio.Root]))
    else
      LSb.AppendLine('RAD Studio: not found (RTL/VCL do not resolve)');
    if FPolicy = gpShared then
      LSb.AppendLine('group policy: shared (one analysis per platform)')
    else
      LSb.AppendLine('group policy: strict (one analysis per configuration)');
    LSb.AppendLine('state: ' + State);
    if not IsReady then
      Exit(LSb.ToString);
    for var LMem in FMembers do
      if LMem.Error <> '' then
        LSb.AppendLine(Format('  member %s: SKIPPED - %s', [LMem.Name,
          LMem.Error]))
      else
        LSb.AppendLine(Format('  member %s: %s %s, %d listed files, analysis %d',
          [LMem.Name, PlatformName(LMem.Platform), IfThen(LMem.Config = '',
          '(bare project file)', LMem.Config),
          Length(LMem.Files), LMem.Analysis]));
    for var LMiss in FMissing do
      LSb.AppendLine('  member missing on disk: ' + RelPath(LMiss));
    for var LA in FAnalyses do
    begin
      if LA.Proj = nil then
        Continue;
      LSb.AppendLine(Format('analysis %d: %d units (%d own), built %d time(s), '
        + 'last %.1f s, %d module run(s)', [LA.Index, LA.Proj.ModelCount,
        LA.OwnModels, LA.Builds, LA.LastBuildMs / 1000, LA.ModuleRuns]));
      // Closure health: an unresolved `uses` is a missing library path, and it
      // silences its importers' diagnostics - the one thing worth knowing
      // before trusting "no references" or "no errors".
      LMissing := TDictionary<string, Integer>.Create;
      LNames := TList<string>.Create;
      try
        for var LMid := 0 to LA.Proj.ModelCount - 1 do
        begin
          LM := LA.Proj.Model(LMid);
          for var LU := 0 to High(LM.UsesList) do
            if LM.UsesList[LU].UnitId < 0 then
            begin
              if not LMissing.TryGetValue(LM.UsesList[LU].NameFull, LN) then
                LN := 0;
              LMissing.AddOrSetValue(LM.UsesList[LU].NameFull, LN + 1);
            end;
        end;
        if LMissing.Count = 0 then
          LSb.AppendLine('  every `uses` name resolved')
        else
        begin
          for var LKey in LMissing.Keys do
            LNames.Add(LKey);
          LNames.Sort;
          LSb.AppendLine(Format('  %d unit name(s) do not resolve (their '
            + 'importers get no diagnostics): %s', [LMissing.Count,
            string.Join(', ', Copy(LNames.ToArray, 0, 15)) +
            IfThen(LNames.Count > 15, ', ...', '')]));
        end;
      finally
        LNames.Free;
        LMissing.Free;
      end;
      for var LFail in LA.Proj.LoadFailures do
        LSb.AppendLine('  INTERNAL parse failure: ' + LFail);
    end;
    LSb.AppendLine('memory held: ' + MemoryText(AllocatedBytes));
    Result := LSb.ToString.TrimRight;
  finally
    LSb.Free;
  end;
end;

end.
