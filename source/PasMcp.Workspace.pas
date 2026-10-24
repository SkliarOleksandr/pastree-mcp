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

  LIGHT MODE (SPEC 9.9). Each analysis' project and navigator belong to a
  PasTree TPasWorkspace (TMcpAnalysis.WS), and the tools ask through it the
  questions a library body can change (references, the hierarchy, renames,
  the lint, defines, one file, one position): the workspace makes the light
  units the answer needs full inside the query, rebuilds or escalates to a
  full analysis when that is cheaper, and the answer is the full analysis'.
  A query that changed the analysis makes the tool start again
  (QueryDone -> EMcpIndexChanged -> CallTool). After an escalation the
  analysis' members stay full for the session (no LightPaths, D9).

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
  PasTree.Sema.Workspace,
  PasMcp.Studio;

type
  TMcpGroupPolicy = (gpShared, gpStrict);

  // Raised by TMcpWorkspace.QueryDone when a workspace query changed the
  // analysis it ran on - light units made full, the project rebuilt or
  // escalated: every model id, symbol index, model and navigator the tool
  // took before it is stale. CallTool runs the tool again from the start;
  // the next run finds the demand met (SPEC 9.9).
  EMcpIndexChanged = class(Exception);

  // What workspace queries did to complete their answers (light mode):
  // per call (the answer's note) and per analysis since the load (`status`).
  TMcpQueryTally = record
    Queries, Completed, Rounds, Promoted, Loaded, Rebuilt, Escalated: Integer;
    Ms: Int64;
    NotSearched: Integer;    // the largest of the call's queries
    Cancelled: Boolean;
    procedure Add(const AStatus: TPasQueryStatus);
  end;

  TMcpMember = record
    ProjectFile: string;     // .dproj or .dpr
    Name: string;
    MainSource: string;
    Platform: TPasPlatform;
    Config: string;
    SearchPaths: TArray<string>;
    Defines: TArray<string>;
    // dcc's `-$` switches the .dproj's DCC_* properties become, in the DCC
    // task's order (TPasDProj.Switches), and its -CC (DCC_ConsoleTarget).
    Switches: TArray<string>;
    ConsoleTarget: Boolean;
    Namespaces: TArray<string>;
    Aliases: TArray<TPasUnitAlias>;
    Files: TArray<string>;   // the .pas files the project lists
    Analysis: Integer;       // index into TMcpWorkspace.Analyses; -1 = failed
    Error: string;
    Extra: Boolean;          // not in the group: given by --also
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
    Switches: TArray<string>;   // the creating member's, as Defines
    ConsoleTarget: Boolean;
    Namespaces: TArray<string>;
    Aliases: TArray<TPasUnitAlias>;
    Pins: TDictionary<string, string>;   // unit name lower -> file
    ProjectDir: string;
    Roots: TArray<string>;
    // The analysis' project and navigator are its workspace's (PasTree
    // TPasWorkspace, which owns both): a query through WS completes its own
    // answer in light mode - the library bodies it needs made full, the
    // project rebuilt or escalated to a full analysis when that is cheaper.
    // Proj and Nav mirror WS.Project and WS.Nav, refreshed after every
    // workspace query (QueryDone) and every own run; never freed here.
    WS: TPasWorkspace;
    Proj: TPasSemaProject;
    Nav: TPasNavigator;
    Stamps: TDictionary<string, TMcpFileStamp>;   // own file (lower) -> stamp
    Paths: TDictionary<string, string>;           // own file (lower) -> path
    OwnModels: Integer;
    LastBuildMs: Int64;
    Builds: Integer;
    ModuleRuns: Integer;
    // Light mode: the directory trees whose units this analysis reads
    // interface-only (TPasSemaProject.LightPaths) - see AssignLightTrees.
    LightTrees: TArray<string>;
    // What the workspace queries of this analysis did since the load, and
    // the units a query could not make full (`file: reason`), for `status`.
    Tally: TMcpQueryTally;
    Refused: TArray<string>;
    constructor Create;
    destructor Destroy; override;
    function MemberNames(const AWorkspace: TObject): string;
  end;

  TMcpWorkspace = class
  private
    FProjectFile: string;
    FRoot: string;
    // Projects outside the group indexed with it (--also), full paths, and
    // the directories of those outside FRoot: their files are own too.
    FExtra: TArray<string>;
    FExtraRoots: TArray<string>;
    FStudioWanted: string;
    FStudio: TMcpStudio;
    // Light mode (SPEC 9.9): on unless --no-light. FLightDirs: the trees
    // --light names, full paths. FLightNotOwn: those of them under the group
    // directory or an --also root and outside every analysis' project
    // directory (which PasTree never reads light) - library, not own.
    FLightOn: Boolean;
    FLightDirs: TArray<string>;
    FLightNotOwn: TArray<string>;
    // The members of an analysis a query escalated to a full analysis
    // (lower-case project files): their analyses stay full for the session,
    // a reload of the workspace included (decision D9 of PasTree's plan).
    FEscalatedMembers: TDictionary<string, Boolean>;
    // The workspace queries of the tool call running (TakeQueryNote), its
    // cancel, whether its queries answer partially (the last run of a tool
    // whose queries kept changing the analysis), and a change QueryDone was
    // told to hold back (RaiseIfChanged).
    FCall: TMcpQueryTally;
    FCallCancelled: TFunc<Boolean>;
    FCallPartial: Boolean;
    // A tool run that keeps changing the analysis is cheaper answered from
    // a full one: its next query escalates (SetPartialQueries' AEager).
    // FEscalationPercent: PasTree's own bound, restored after the call.
    FCallEager: Boolean;
    FEscalationPercent: Integer;
    FChangePending: Boolean;
    FPlatformOverride: string;
    FConfig: string;
    FPolicy: TMcpGroupPolicy;
    FMembers: TArray<TMcpMember>;
    FMissing: TArray<string>;
    FAnalyses: TObjectList<TMcpAnalysis>;
    FLibDirs: TArray<string>;
    FLibTrees: TArray<string>;   // FLibDirs normalized, for IsProjectSource
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
    // A project configured as AAnalysis is analyzed - search paths, defines,
    // namespaces, aliases, switches, pins, light trees - and NOT analyzed:
    // BuildAnalysis' first step, and its workspace's factory for the
    // rebuilds a query needs.
    function NewProject(AAnalysis: TMcpAnalysis): TPasSemaProject;
    procedure BuildAnalysis(AAnalysis: TMcpAnalysis; AUseDonor: Boolean);
    // The text layer of every library unit freed (EnsureHydrated reads it
    // back on demand); the own units kept warm for the module path.
    procedure DemoteLibraryText(AProject: TPasSemaProject);
    // The query options of AAnalysis' workspace: escalation run (decision
    // D8), progress to the log, the call's cancel and partial mode.
    procedure ApplyQueryOptions(AAnalysis: TMcpAnalysis);
    // Proj and Nav set to the workspace's; a project the workspace replaced
    // (a rebuild, an escalation) demoted and stamped as a build's is.
    procedure SyncAnalysis(AAnalysis: TMcpAnalysis);
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
    procedure AssignLightTrees;
    procedure AppendLightStatus(ASb: TStringBuilder; AA: TMcpAnalysis);
  public
    // AExtra: projects outside the group to index with it, as its members are
    // (the client group's tests are a project no .groupproj lists).
    constructor Create(const AProjectFile, AStudio, APlatform, AConfig: string;
      APolicy: TMcpGroupPolicy; const AExtra: TArray<string> = nil);
    destructor Destroy; override;
    // Light mode: AOn False is --no-light; ADirs the --light trees, relative
    // to the project's directory or absolute. Before Load.
    procedure SetLight(AOn: Boolean; const ADirs: TArray<string>);
    property LightOn: Boolean read FLightOn;
    // A tool call starts (CallTool): its tally cleared; ACancelled (nil:
    // none) is what every workspace query polls.
    procedure BeginCall(const ACancelled: TFunc<Boolean>);
    // The queries of the tool's next run answer partially (Options.Partial):
    // no unit made full, what light bodies hold counted in NotSearched.
    // AEager: a query that needs any unit made full escalates instead (the
    // run after several the queries changed: each run repeats the whole
    // walk, and one rebuild costs less than the walks) - for this call.
    procedure SetPartialQueries(APartial: Boolean; AEager: Boolean = False);
    // After every query through AAnalysis.WS: its Status tallied, logged
    // when it did anything, an escalation remembered (D9), Proj and Nav
    // synced - and, when the query changed the analysis, EMcpIndexChanged
    // raised (ADefer: remembered for RaiseIfChanged instead, for a tool that
    // asks a batch of completions before it reads anything).
    procedure QueryDone(AAnalysis: TMcpAnalysis; ADefer: Boolean = False);
    procedure RaiseIfChanged;
    // What the call's queries leave to say on its answer, '' for nothing:
    // an escalation ("the library was analyzed in full for this answer; the
    // analysis stays full") and NotSearched ("library implementations not
    // searched: N units"). An answer completed without either says nothing:
    // it is the full analysis' answer.
    function TakeQueryNote: string;
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
    // An own file, or a source the members' search paths reach outside the
    // installed library (the Studio tree, its library and browsing paths) -
    // code maintained beside the group, like a sibling repository's units.
    // `references` scans these for uses in branches not compiled: own files
    // alone left such a unit's uncompiled uses unsaid, and the installed
    // library is too large to scan per call.
    function IsProjectSource(const APath: string): Boolean;
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
    // The --studio given, set before Load: Studio is Load's, on the thread
    // that runs the tools, and `initialize` is answered before that.
    property StudioWanted: string read FStudioWanted;
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
  PasTree.Preprocessor,
  PasMcp.Log,
  PasMcp.Version,
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

function UnitNameOfPath(const APath: string): string;
begin
  Result := ChangeFileExt(ExtractFileName(APath), '');
end;

function Plural(ACount: Integer; const AWord: string): string;
begin
  Result := Format('%d %s%s', [ACount, AWord, IfThen(ACount = 1, '', 's')]);
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

{ TMcpQueryTally }

procedure TMcpQueryTally.Add(const AStatus: TPasQueryStatus);
begin
  Inc(Queries);
  if (AStatus.Rounds > 0) or AStatus.Rebuilt or AStatus.Escalated then
    Inc(Completed);
  Inc(Rounds, AStatus.Rounds);
  Inc(Promoted, AStatus.Promoted);
  Inc(Loaded, AStatus.Loaded);
  if AStatus.Rebuilt then
    Inc(Rebuilt);
  if AStatus.Escalated then
    Inc(Escalated);
  Inc(Ms, AStatus.Ms);
  NotSearched := Max(NotSearched, AStatus.NotSearched);
  Cancelled := Cancelled or AStatus.Cancelled;
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
  // The workspace owns the project and the navigator Proj and Nav mirror.
  WS.Free;
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
  AConfig: string; APolicy: TMcpGroupPolicy; const AExtra: TArray<string>);
var
  LDir: string;
begin
  inherited Create;
  FProjectFile := TPath.GetFullPath(AProjectFile);
  FRoot := TPath.GetDirectoryName(FProjectFile);
  for var LOne in AExtra do
  begin
    if SameText(TPath.GetFullPath(LOne), FProjectFile) then
      Continue;
    FExtra := FExtra + [TPath.GetFullPath(LOne)];
    LDir := TPath.GetDirectoryName(TPath.GetFullPath(LOne));
    if not StartsText(IncludeTrailingPathDelimiter(FRoot),
      IncludeTrailingPathDelimiter(LDir)) and (IndexText(LDir, FExtraRoots) < 0)
    then
      FExtraRoots := FExtraRoots + [LDir];
  end;
  FStudioWanted := AStudio;
  FPlatformOverride := APlatform;
  FConfig := AConfig;
  FPolicy := APolicy;
  FLightOn := True;
  FAnalyses := TObjectList<TMcpAnalysis>.Create(True);
  FEscalatedMembers := TDictionary<string, Boolean>.Create;
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
  FEscalatedMembers.Free;
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
  if FListed.ContainsKey(LowerCase(APath)) then
    Exit(True);
  // A tree --light names inside the group is somebody else's code.
  if (FLightNotOwn <> nil) and PasUnderDirTrees(APath, FLightNotOwn) then
    Exit(False);
  Result := StartsText(IncludeTrailingPathDelimiter(FRoot), APath);
  if not Result then
    for var LDir in FExtraRoots do
      if StartsText(IncludeTrailingPathDelimiter(LDir), APath) then
        Exit(True);
end;

function TMcpWorkspace.IsProjectSource(const APath: string): Boolean;
begin
  // Not the trees --light names: light mode changes how a unit is read, never
  // an answer (the light fixture's every answer equals the full run's).
  Result := IsOwnFile(APath) or not PasUnderDirTrees(APath, FLibTrees);
end;

procedure TMcpWorkspace.SetLight(AOn: Boolean; const ADirs: TArray<string>);
begin
  FLightOn := AOn;
  FLightDirs := nil;
  for var LDir in ADirs do
    FLightDirs := FLightDirs + [ExcludeTrailingPathDelimiter(FullPath(LDir))];
end;

// Light mode (SPEC 9.9): an analysis reads the units of the installed
// library interface-only - the registry's library and browsing paths and the
// Studio source trees, the directories the navigator calls library - and the
// trees --light adds. Own code stays full: a library tree under the group
// directory or an --also root (the in-repo patched copies of a library are
// own, SPEC 4), or one holding either of them or a file a member lists, is
// left out - PasTree exempts the listed files, the roots and the project
// directory itself (D7), but not the rest of the group directory. An --light
// tree is kept as named; under a project directory PasTree reads it full
// all the same, which the log says.
procedure TMcpWorkspace.AssignLightTrees;
var
  LOwnTrees, LListed: TArray<string>;
  LTree: string;
  LDrop: Boolean;
begin
  LOwnTrees := PasNormalizeDirTrees([FRoot] + FExtraRoots);
  LListed := nil;
  for var LKey in FListed.Keys do
    LListed := LListed + [LKey];
  FLightNotOwn := nil;
  for var LDir in PasNormalizeDirTrees(FLightDirs) do
  begin
    if not PasUnderDirTrees(LDir, LOwnTrees) then
      Continue;
    LDrop := False;
    for var LA in FAnalyses do
      if PasUnderDirTrees(LDir, PasNormalizeDirTrees([LA.ProjectDir])) then
      begin
        Log('--light %s lies under the project directory of analysis %d (%s) '
          + '- PasTree never reads that directory light; its units stay own '
          + 'and full', [LDir, LA.Index, LA.ProjectDir]);
        LDrop := True;
        Break;
      end;
    if not LDrop then
      FLightNotOwn := FLightNotOwn + [LDir];
  end;
  for var LA in FAnalyses do
  begin
    LA.LightTrees := nil;
    if not FLightOn then
      Continue;
    // A query escalated an analysis of these members to a full one: it
    // stays full for the session (D9), through a reload too.
    LDrop := False;
    for var LIdx in LA.Members do
      LDrop := LDrop or FEscalatedMembers.ContainsKey(
        LowerCase(FMembers[LIdx].ProjectFile));
    if LDrop then
      Continue;
    for LTree in PasNormalizeDirTrees(FStudio.LibraryPaths(LA.Platform)) do
    begin
      // Under the group (own by SPEC 4), or holding it or a listed file.
      LDrop := PasUnderDirTrees(LTree, LOwnTrees);
      for var LOwn in LOwnTrees do
        LDrop := LDrop or StartsStr(LTree, LOwn);
      for var LFile in LListed do
        LDrop := LDrop or StartsStr(LTree, LFile);
      if not LDrop and (IndexStr(LTree, LA.LightTrees) < 0) then
        LA.LightTrees := LA.LightTrees + [LTree];
    end;
    for LTree in PasNormalizeDirTrees(FLightDirs) do
      if IndexStr(LTree, LA.LightTrees) < 0 then
        LA.LightTrees := LA.LightTrees + [LTree];
  end;
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
  begin
    Result := '';
    for var LMem in FMembers do
      if LMem.Extra then
        Result := Result + ' + ' + TPath.GetFileName(LMem.ProjectFile);
    Result := Format('the %d projects of %s%s', [Length(FMembers),
      TPath.GetFileName(FProjectFile), Result]);
  end;
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
      begin
        // Light mode: what a full analysis reads beyond the loaded models -
        // the units only library implementations use, and the include
        // files of light implementations - is not outside the index.
        var LUnits, LIncludes: TArray<string>;
        LA.Proj.NotLoadedFiles(LUnits, LIncludes);
        for var LFile in LUnits + LIncludes do
          LIndexed.AddOrSetValue(LowerCase(LFile), True);
        for var LMid := 0 to LA.Proj.ModelCount - 1 do
        begin
          LIndexed.AddOrSetValue(LowerCase(LA.Proj.ModelFile(LMid)), True);
          // Its includes too: a demoted model keeps its file names.
          for var LFile in LA.Proj.Model(LMid).Tree.Source.FileNames do
            if LFile <> '' then
              LIndexed.AddOrSetValue(LowerCase(LFile), True);
        end;
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
  LExt, LFile: string;
  LGroupCount: Integer;
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
  LGroupCount := Length(LFiles);
  for var LOne in FExtra do
    if not TFile.Exists(LOne) then
      FMissing := FMissing + [LOne]
    else if IndexText(LOne, LFiles) < 0 then
      LFiles := LFiles + [LOne];

  for var LIdx := 0 to High(LFiles) do
  begin
    LFile := LFiles[LIdx];
    LM := Default(TMcpMember);
    LM.ProjectFile := LFile;
    LM.Name := TPath.GetFileNameWithoutExtension(LFile);
    LM.Analysis := -1;
    LM.Extra := LIdx >= LGroupCount;
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
          LM.Switches := LD.Switches;
          LM.ConsoleTarget := LD.ConsoleTarget;
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
        LowerCase(string.Join(';', AM.Namespaces)) + '|' + LAl + '|' +
        UpperCase(string.Join(' ', AM.Switches)) + '|' +
        BoolToStr(AM.ConsoleTarget, True);
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
          if not TFile.Exists(LF) then
            Continue;   // not pinned, see below
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
        LA.Switches := FMembers[LIdx].Switches;
        LA.ConsoleTarget := FMembers[LIdx].ConsoleTarget;
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
      if (LA.Members <> nil) and
         ((not SameText(string.Join(' ', LA.Switches),
           string.Join(' ', FMembers[LIdx].Switches))) or
          (LA.ConsoleTarget <> FMembers[LIdx].ConsoleTarget)) then
        Log('  %s shares analysis %d but its switches differ: its own [%s%s], '
          + 'analyzed with [%s%s]', [FMembers[LIdx].Name, LA.Index,
          string.Join(' ', FMembers[LIdx].Switches),
          IfThen(FMembers[LIdx].ConsoleTarget, ' -CC', ''),
          string.Join(' ', LA.Switches), IfThen(LA.ConsoleTarget, ' -CC', '')]);
      LA.Members := LA.Members + [LIdx];
      FMembers[LIdx].Analysis := LA.Index;
      LA.Roots := LA.Roots + [FMembers[LIdx].MainSource];
      AddUnique(LA.Namespaces, FMembers[LIdx].Namespaces);
      // A listed file that does not exist is not pinned: dcc compiles the unit
      // the search path finds (the client group's server lists one in its
      // .dpr and .dproj and builds), and a pin to it made every importer
      // F1027 - and split the analysis over a "second location" that is not
      // there. PasTree drops such a pin too (0.91.1); left out here, it does
      // not decide which analysis a member joins.
      for var LF in FMembers[LIdx].Files do
        if TFile.Exists(LF) then
          LA.Pins.AddOrSetValue(LowerCase(TPath.GetFileNameWithoutExtension(LF)),
            LF)
        else
          Log('  %s lists %s, which does not exist - the unit is looked up on '
            + 'the search path, as dcc does', [FMembers[LIdx].Name, LF]);
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

function TMcpWorkspace.NewProject(AAnalysis: TMcpAnalysis): TPasSemaProject;
begin
  if FStudio.Found then
    Result := TPasSemaProject.Create(AAnalysis.Platform, AAnalysis.SearchPaths,
      AAnalysis.Defines, FStudio.CompilerVersion)
  else
    Result := TPasSemaProject.Create(AAnalysis.Platform, AAnalysis.SearchPaths,
      AAnalysis.Defines);
  try
    Result.SetNamespaces(AAnalysis.Namespaces);
    for var LAl in AAnalysis.Aliases do
      Result.AddUnitAlias(LAl.Alias, LAl.UnitName);
    Result.SetProjectDir(AAnalysis.ProjectDir);
    // The state every unit starts in: without it a Release config's
    // `{$IFOPT D+}` code was compiled for the index and a console program's
    // units had no CONSOLE (PasTree 0.106.0).
    Result.SwitchStart := PasStartOptState(AAnalysis.Switches);
    Result.ConsoleTarget := AAnalysis.ConsoleTarget;
    for var LPin in AAnalysis.Pins.Values do
      Result.PinUnitFile(LPin);
    // Library units interface-only (SPEC 9.9) - none once a query escalated
    // this analysis (D9: it stays full; LightTrees is cleared then too). A
    // donor brings the units made full before (PromotedFiles), which stay
    // full.
    if (AAnalysis.WS = nil) or not AAnalysis.WS.Escalated then
      Result.LightPaths := AAnalysis.LightTrees;
    // The same switch pastree-lsp turns on: a member after a dot that nothing
    // resolves is E2003 too, and PasTree's corpus runs report zero false ones.
    Result.ReportUnresolvedMembers := True;
  except
    Result.Free;
    raise;
  end;
end;

procedure TMcpWorkspace.DemoteLibraryText(AProject: TPasSemaProject);
var
  LKeep: TList<string>;
begin
  LKeep := TList<string>.Create;
  try
    for var LMid := 0 to AProject.ModelCount - 1 do
      if IsOwnFile(AProject.ModelFile(LMid)) then
        LKeep.Add(AProject.ModelFile(LMid));
    AProject.DemoteText(LKeep.ToArray);
  finally
    LKeep.Free;
  end;
end;

procedure TMcpWorkspace.BuildAnalysis(AAnalysis: TMcpAnalysis;
  AUseDonor: Boolean);
var
  LProj, LDonor: TPasSemaProject;
  LSW: TStopwatch;
  LLast: Int64;
  LPrefix: string;
  LIdx: Integer;
begin
  LPrefix := Format('analysis %d (%s)', [AAnalysis.Index,
    AAnalysis.MemberNames(Self)]);
  Log('%s: %s, %d roots, %d search paths, %d defines [%s], switches [%s], '
    + '-CC %s', [LPrefix, PlatformName(AAnalysis.Platform),
    Length(AAnalysis.Roots), Length(AAnalysis.SearchPaths),
    Length(AAnalysis.Defines), string.Join(';', AAnalysis.Defines),
    string.Join(' ', AAnalysis.Switches),
    IfThen(AAnalysis.ConsoleTarget, 'on', 'off')]);
  LProj := NewProject(AAnalysis);
  try
    // The old project donates every unchanged parse: lent by its workspace
    // for the run (the workspace then refuses a query that would change it).
    LDonor := nil;
    if AUseDonor and (AAnalysis.WS <> nil) then
      LDonor := AAnalysis.WS.Lend;
    try
      if (LDonor <> nil) and not LProj.AdoptParseDonor(LDonor) then
        Log('%s: parse donor refused (configuration changed, or its last run '
          + 'did not complete) - every unit is parsed again', [LPrefix]);
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
    finally
      if LDonor <> nil then
        AAnalysis.WS.EndLend;
    end;
    AAnalysis.LastBuildMs := LSW.ElapsedMilliseconds;
    Inc(AAnalysis.Builds);
    DemoteLibraryText(LProj);
  except
    LProj.Free;
    raise;
  end;
  // The workspace takes the project (and frees the one before it).
  if AAnalysis.WS = nil then
  begin
    LIdx := AAnalysis.Index;
    AAnalysis.WS := TPasWorkspace.Create(LProj,
      function: TPasSemaProject
      begin
        Result := NewProject(FAnalyses[LIdx]);
      end);
    AAnalysis.WS.LibraryPaths := FLibDirs;
    ApplyQueryOptions(AAnalysis);
  end
  else
    AAnalysis.WS.Adopt(LProj);
  AAnalysis.Proj := AAnalysis.WS.Project;
  AAnalysis.Nav := AAnalysis.WS.Nav;
  RecordStamps(AAnalysis);
  Log('%s: %d units (%d own, %d light, %d promoted) in %.1f s, %s held; '
    + 'stages %s', [LPrefix, LProj.ModelCount, AAnalysis.OwnModels,
    LProj.LightCount, Length(LProj.PromotedFiles), AAnalysis.LastBuildMs /
    1000, MemoryText(AllocatedBytes), LProj.StageTimings]);
  // An unreadable file (held open exclusively) or an analyzer defect: its
  // importers get F1027 naming the exception (PasTree 0.95.7).
  if Length(LProj.LoadFailures) > 0 then
    for var LFail in LProj.LoadFailures do
      Log('%s: a unit could not be analyzed: %s', [LPrefix, LFail]);
end;

procedure TMcpWorkspace.ApplyQueryOptions(AAnalysis: TMcpAnalysis);
var
  LOpt: TPasQueryOptions;
  LIdx: Integer;
  LLast: Int64;
  LSW: TStopwatch;
begin
  LIdx := AAnalysis.Index;
  LOpt := Default(TPasQueryOptions);
  // Decision D8: an escalation runs, with progress (to the log - an MCP
  // answer has no status bar, and `status` waits in the call queue).
  LOpt.Escalation := esRun;
  LOpt.Partial := FCallPartial;
  LOpt.Cancelled := FCallCancelled;
  // 1 %: any demand past the volume made full so far escalates (0 would
  // turn escalation off). A rebuild's project takes the bound over, so the
  // next call's BeginCall puts PasTree's own back on every project.
  if AAnalysis.WS.Project <> nil then
  begin
    if FEscalationPercent = 0 then
      FEscalationPercent := AAnalysis.WS.Project.EscalationPercent;
    AAnalysis.WS.Project.EscalationPercent := IfThen(FCallEager, 1,
      FEscalationPercent);
  end;
  LSW := TStopwatch.StartNew;
  LLast := -10000;
  LOpt.OnProgress :=
    procedure(AP: TPasQueryProgress)
    begin
      // A round each; a rebuild's analysis every 5 s (called from its
      // worker threads too: Log is thread-safe).
      if (AP.Stage = qsPromote) or (LSW.ElapsedMilliseconds - LLast >= 5000)
      then
      begin
        LLast := LSW.ElapsedMilliseconds;
        Log('analysis %d: completing an answer - %s', [LIdx, AP.Text]);
      end;
    end;
  AAnalysis.WS.Options := LOpt;
end;

procedure TMcpWorkspace.SyncAnalysis(AAnalysis: TMcpAnalysis);
begin
  if AAnalysis.WS = nil then
    Exit;
  if AAnalysis.Proj <> AAnalysis.WS.Project then
  begin
    // Rebuilt or escalated by a query: as after a build - the library text
    // demoted (a fresh navigator after it), the own files stamped.
    DemoteLibraryText(AAnalysis.WS.Project);
    AAnalysis.WS.Adopt(AAnalysis.WS.Project);
    AAnalysis.Proj := AAnalysis.WS.Project;
    AAnalysis.Nav := AAnalysis.WS.Nav;
    Inc(AAnalysis.Builds);
    RecordStamps(AAnalysis);
    RebuildOwners;
    RecordFormStamps;
  end;
  AAnalysis.Proj := AAnalysis.WS.Project;
  AAnalysis.Nav := AAnalysis.WS.Nav;
end;

procedure TMcpWorkspace.BeginCall(const ACancelled: TFunc<Boolean>);
begin
  FCall := Default(TMcpQueryTally);
  FChangePending := False;
  FCallCancelled := ACancelled;
  FCallPartial := False;
  FCallEager := False;
  for var LA in FAnalyses do
    if LA.WS <> nil then
      ApplyQueryOptions(LA);
end;

procedure TMcpWorkspace.SetPartialQueries(APartial, AEager: Boolean);
begin
  FCallPartial := APartial;
  FCallEager := AEager;
  for var LA in FAnalyses do
    if LA.WS <> nil then
      ApplyQueryOptions(LA);
end;

procedure TMcpWorkspace.QueryDone(AAnalysis: TMcpAnalysis; ADefer: Boolean);
var
  LStatus: TPasQueryStatus;
begin
  LStatus := AAnalysis.WS.Status;
  FCall.Add(LStatus);
  AAnalysis.Tally.Add(LStatus);
  for var LR in LStatus.Refused do
    if IndexText(LR, AAnalysis.Refused) < 0 then
      AAnalysis.Refused := AAnalysis.Refused + [LR];
  if (LStatus.Rounds > 0) or LStatus.Rebuilt or LStatus.Escalated or
     (LStatus.NotSearched > 0) then
    Log('analysis %d: a query completed its answer: %d round(s), %d unit(s) '
      + 'made full, %d taken in%s%s in %d ms%s%s', [AAnalysis.Index,
      LStatus.Rounds, LStatus.Promoted, LStatus.Loaded,
      IfThen(LStatus.Rebuilt, ', the analysis rebuilt', ''),
      IfThen(LStatus.Escalated, ', ESCALATED to a full analysis', ''),
      LStatus.Ms, IfThen(LStatus.NotSearched > 0, Format(', %d unit(s) not '
      + 'searched%s', [LStatus.NotSearched, IfThen(LStatus.Cancelled,
      ' (cancelled)', '')]), ''), IfThen(LStatus.Refused <> nil,
      ', refused: ' + string.Join('; ', LStatus.Refused), '')]);
  if LStatus.Escalated then
  begin
    // D9: full for the session - the next analyses of these members too.
    AAnalysis.LightTrees := nil;
    for var LIdx in AAnalysis.Members do
      FEscalatedMembers.AddOrSetValue(LowerCase(FMembers[LIdx].ProjectFile),
        True);
  end;
  if not LStatus.Changed then
    Exit;
  SyncAnalysis(AAnalysis);
  if ADefer then
    FChangePending := True
  else
    raise EMcpIndexChanged.Create('the analysis changed under the query');
end;

procedure TMcpWorkspace.RaiseIfChanged;
begin
  if FChangePending then
  begin
    FChangePending := False;
    raise EMcpIndexChanged.Create('the analysis changed under the query');
  end;
end;

function TMcpWorkspace.TakeQueryNote: string;
begin
  Result := '';
  if FCall.Escalated > 0 then
    Result := 'the library was analyzed in full for this answer; the '
      + 'analysis stays full';
  if FCall.NotSearched > 0 then
    Result := Result + IfThen(Result <> '', '; ') + Format('library '
      + 'implementations not searched: %d units%s', [FCall.NotSearched,
      IfThen(FCall.Cancelled, ' (cancelled)', '')]);
  FCall := Default(TMcpQueryTally);
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
      AssignLightTrees;
      if not FLightOn then
        Log('light mode off (--no-light): library units are analyzed in full')
      else
        for var LA in FAnalyses do
          Log('analysis %d: light mode, %d library trees read interface-only%s',
            [LA.Index, Length(LA.LightTrees), IfThen(FLightDirs <> nil,
            ' (--light: ' + string.Join('; ', FLightDirs) + ')', '')]);
      FLibDirs := nil;
      if FStudio.Found then
        FLibDirs := [FStudio.Root];
      for var LA in FAnalyses do
        AddUnique(FLibDirs, FStudio.LibraryPaths(LA.Platform));
      FLibTrees := PasNormalizeDirTrees(FLibDirs);
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
        BuildAnalysis(LA, False);
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

// ` (<reason>)` from the `module=refused:<reason>;` a refused module run
// leaves in StageTimings, or '' when it left none (the run raised).
function ModuleRefusalText(const ATimings: string): string;
const
  cTag = 'module=refused:';
var
  LAt, LEnd: Integer;
begin
  Result := '';
  LAt := Pos(cTag, ATimings);
  if LAt = 0 then
    Exit;
  Inc(LAt, Length(cTag));
  LEnd := Pos(';', ATimings, LAt);
  if LEnd = 0 then
    LEnd := Length(ATimings) + 1;
  Result := ' (' + Copy(ATimings, LAt, LEnd - LAt) + ')';
end;

procedure TMcpWorkspace.RebuildAnalysis(AAnalysis: TMcpAnalysis;
  const AWhy: string);
begin
  Log('analysis %d: full rebuild - %s', [AAnalysis.Index, AWhy]);
  // The old project donates every unchanged parse (its workspace lends it
  // for the run, then adopts the new one and frees it).
  BuildAnalysis(AAnalysis, True);
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
  LRunProj: TPasSemaProject;
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
      // The module runs change the project in place: its workspace hands it
      // out for them (Release) and takes it back (Adopt), with a navigator
      // made afresh - a navigator kept across a run raises (PasTree 0.96.0).
      LRunProj := nil;
      if LNeedRebuild = '' then
      begin
        LRunProj := LA.WS.Release;
        LA.Nav := nil;
      end;
      if LNeedRebuild = '' then
      try
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
            // PasTree leaves the reason in StageTimings as
            // `module=refused:<reason>;` (incomplete-run, needs-full-rebuild,
            // in-path-changed(<unit>), implicit-unit(<unit>), ...).
            LNeedRebuild := 'the module path refused ' + RelPath(LFile) +
              ModuleRefusalText(LA.Proj.StageTimings);
            Break;
          end;
          Inc(LA.ModuleRuns);
          if StampOf(LFile, LStamp) then
            LA.Stamps.AddOrSetValue(LowerCase(LFile), LStamp);
        end;
      finally
        LA.WS.Adopt(LRunProj);
        LA.Proj := LA.WS.Project;
        LA.Nav := LA.WS.Nav;
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

// The light-mode lines of `status` for one analysis: how many units are read
// interface-only and promoted, and two hints for an --light the group may
// want - directories of own units no member lists one of (an in-repo copy of
// a library, read in full as own), and own units named as a library unit is
// (a patched copy).
procedure TMcpWorkspace.AppendLightStatus(ASb: TStringBuilder;
  AA: TMcpAnalysis);
const
  MAX_HINTS = 5;
var
  LDirs: TDictionary<string, Integer>;   // dir -> unlisted own units, -1 = one listed
  LShadows: TArray<string>;
  LFile, LDir, LName: string;
  LN: Integer;
  LKeys: TArray<string>;
begin
  if not FLightOn then
  begin
    ASb.AppendLine('  light mode off (--no-light): library units analyzed in '
      + 'full');
    Exit;
  end;
  if AA.WS.Escalated then
    ASb.AppendLine('  light mode: escalated - a query needed the library in '
      + 'full, and the analysis stays full for the session')
  else
    ASb.AppendLine(Format('  light mode: %d of %d units are library units '
      + 'read interface-only (a query needing their bodies analyzes them in '
      + 'full first); %d made full so far', [AA.Proj.LightCount,
      AA.Proj.ModelCount, Length(AA.Proj.PromotedFiles)]));
  // What the queries paid for answers equal to a full analysis'.
  ASb.AppendLine(Format('  queries completed in light mode: %d of %d, %d '
    + 'round(s), %d unit(s) made full, %d taken in, %d rebuild(s), %d '
    + 'escalation(s), %d ms%s', [AA.Tally.Completed, AA.Tally.Queries,
    AA.Tally.Rounds, AA.Tally.Promoted, AA.Tally.Loaded, AA.Tally.Rebuilt,
    AA.Tally.Escalated, AA.Tally.Ms, IfThen(AA.Refused <> nil,
    '; refused: ' + string.Join(', ', Copy(AA.Refused, 0, MAX_HINTS)) +
    IfThen(Length(AA.Refused) > MAX_HINTS, ', ...'), '')]));
  LDirs := TDictionary<string, Integer>.Create;
  try
    LShadows := nil;
    for var LMid := 0 to AA.Proj.ModelCount - 1 do
    begin
      LFile := AA.Proj.ModelFile(LMid);
      if not IsOwnFile(LFile) or not SameText(ExtractFileExt(LFile), '.pas') then
        Continue;
      LDir := ExtractFileDir(LFile);
      if FListed.ContainsKey(LowerCase(LFile)) then
        LDirs.AddOrSetValue(LDir, -1)
      else
      begin
        if not LDirs.TryGetValue(LDir, LN) then
          LN := 0;
        if LN >= 0 then
          LDirs.AddOrSetValue(LDir, LN + 1);
        LName := ExtractFileName(LFile);
        for var LTree in AA.LightTrees do
          if TFile.Exists(LTree + LName) then
          begin
            LShadows := LShadows + [RelPath(LFile)];
            Break;
          end;
      end;
    end;
    LKeys := nil;
    for var LPair in LDirs do
      if LPair.Value > 0 then
        LKeys := LKeys + [Format('%s (%d)', [RelPath(LPair.Key), LPair.Value])];
    TArray.Sort<string>(LKeys);
    if LKeys <> nil then
      ASb.AppendLine(Format('  own units in %d directories no member lists a '
        + 'unit of, read in full: %s - if that is a library''s code, '
        + '`--light <dir>` reads it interface-only', [Length(LKeys),
        string.Join(', ', Copy(LKeys, 0, MAX_HINTS)) + IfThen(Length(LKeys) >
        MAX_HINTS, ', ...')]));
    if LShadows <> nil then
      ASb.AppendLine(Format('  %d own unit(s) named as a unit of a library '
        + 'directory (a patched copy?), read in full: %s', [Length(LShadows),
        string.Join(', ', Copy(LShadows, 0, MAX_HINTS)) + IfThen(
        Length(LShadows) > MAX_HINTS, ', ...')]));
  finally
    LDirs.Free;
  end;
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
    // Which process answered: with a dozen servers of different builds
    // running, finding it took the process list and strings from the renamed
    // exe copies.
    LSb.AppendLine(Format('server: %s; pid %d, started %s', [PasMcpVersionBanner,
      GetCurrentProcessId, FormatDateTime('yyyy-mm-dd hh:nn', ProcessStarted)]));
    LSb.AppendLine('log: ' + IfThen(LogFile = '', 'none (stderr only)', LogFile));
    LSb.AppendLine('project: ' + FProjectFile);
    LSb.AppendLine('paths in results are relative to: ' + FRoot);
    if FStudio.Found then
    begin
      LSb.AppendLine(Format('RAD Studio %s (dcc %.1f) at %s', [FStudio.Version,
        FStudio.CompilerVersion, FStudio.Root]));
      LSb.AppendLine('language: ' + LanguageNote(FStudio));
    end
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
        LSb.AppendLine(Format('  member %s: %s %s, %d listed files, analysis %d%s',
          [LMem.Name, PlatformName(LMem.Platform), IfThen(LMem.Config = '',
          '(bare project file)', LMem.Config),
          Length(LMem.Files), LMem.Analysis, IfThen(LMem.Extra,
          ' - not in the group, added by --also (' + RelPath(LMem.ProjectFile) +
          ')', '')]));
    for var LMiss in FMissing do
      LSb.AppendLine('  member missing on disk: ' + RelPath(LMiss));
    for var LA in FAnalyses do
    begin
      if LA.Proj = nil then
        Continue;
      LSb.AppendLine(Format('analysis %d: %d units (%d own), built %d time(s), '
        + 'last %.1f s, %d module run(s)', [LA.Index, LA.Proj.ModelCount,
        LA.OwnModels, LA.Builds, LA.LastBuildMs / 1000, LA.ModuleRuns]));
      AppendLightStatus(LSb, LA);
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
            // UNIT_NOT_LOADED: a light unit's implementation `uses`, resolved
            // and on purpose not loaded - not a missing unit.
            if LM.UsesList[LU].UnitId = NIL_SYM then
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
        LSb.AppendLine('  could not be analyzed (an unreadable file or an '
          + 'analyzer defect): ' + LFail);
      // A library unit demoted to save memory is read back on demand; one
      // whose file changed or went since cannot be (PasTree 0.97.0).
      if LA.Proj.HydrateFailures > 0 then
        LSb.AppendLine(Format('  %d unit text(s) could not be read back - '
          + 'changed on disk since the analysis, the last %s',
          [LA.Proj.HydrateFailures,
          RelPath(LA.Proj.ModelFile(LA.Proj.LastHydrateFailure))]));
    end;
    LSb.AppendLine('memory held: ' + MemoryText(AllocatedBytes));
    Result := LSb.ToString.TrimRight;
  finally
    LSb.Free;
  end;
end;

end.
