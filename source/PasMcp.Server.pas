unit PasMcp.Server;

{
  The JSON-RPC side of MCP: initialize, ping, tools/list, tools/call.

  Deliberately the smallest server the protocol allows - tools only, no
  resources, prompts, sampling or subscriptions. `instructions` in the
  initialize result is the one extra: Claude Code puts it in front of the
  model, and it is where the model learns WHEN to reach for these tools
  instead of grep.

  Threads:

  - The main thread reads stdin and never waits for a tool. initialize, ping
    and tools/list are answered there, a tools/call goes to the queue, and
    notifications/cancelled is acted on at once.
  - One executor thread runs the calls of the queue one at a time, in the
    order they came. Every tool reads the index, and the index is not safe to
    read from two threads: a query hydrates library units, the freshness
    check re-analyzes changed files and replaces the navigator.
  - A tool that answers later (PasMcp.Tools.TDeferredTool: `compile`) does
    its work on a thread of its own that reads nothing of the index, and its
    Finish comes back through the queue. So a build of minutes holds no call
    behind it, and its answer may come after theirs: JSON-RPC matches an
    answer to its request by id.
  - Writes to stdout are serialized by TMcpTransport, a message at a time.

  The initial analysis runs on a thread of its own too, started once the
  project is known (Settle). A client with MCP roots is asked for them after
  the handshake: the session's directory may hold another project than the
  one found from the directory the server was started in - the Claude
  desktop app starts the servers of a session in a git worktree in the main
  checkout - and the load waits for the answer, ROOTS_WAIT_MS at most. A tool
  call waits for the load (PasMcp.Tools.CallTool); the handshake and
  `status` never do.

  A cancelled request (notifications/cancelled) is not answered, as MCP asks:
  dropped while still queued, its answer suppressed once running, and a
  deferred tool's work stopped - `compile` kills the build's process tree.

  A tools/call whose params carry `_meta.progressToken` gets
  notifications/progress while it runs, from a tool that reports (`compile`).
  Claude Code aborts a call to a stdio server that sends neither a response
  nor a progress notification for 30 minutes (its MCP documentation), so a
  notification keeps a long build alive, and the message shows what it does.

  The server lives as long as the process: it is never freed, and the process
  ends by ExitProcess when stdin closes, whatever is still running.
}

interface

uses
  System.JSON,
  System.SyncObjs,
  System.Generics.Collections,
  PasMcp.Transport,
  PasMcp.Workspace,
  PasMcp.Tools;

type
  TMcpTaskKind = (mtCall, mtFinish);

  // A tools/call on its way through the queue: its call, then - for a
  // deferred tool - its Finish.
  TMcpTask = class
  public
    Kind: TMcpTaskKind;
    Id: TJSONValue;        // owned clone
    Key: string;           // Id as JSON, what notifications/cancelled names
    Name: string;
    Args: TJSONObject;     // owned clone, or nil
    Token: string;         // _meta.progressToken as JSON, '' when none
    Job: TDeferredTool;    // owned; set under TMcpServer's lock
    Cancelled: Boolean;    // under TMcpServer's lock
    destructor Destroy; override;
  end;

  // The session's directory as the client gives it -> the workspace to use
  // instead of the one the server was started with, or nil to keep that.
  // ANote: what `status` says of it.
  TMcpRootWorkspace = reference to function(const ADir: string;
    out ANote: string): TMcpWorkspace;

  TMcpServer = class
  private
    FWs: TMcpWorkspace;
    FTransport: TMcpTransport;
    FQueue: TThreadedQueue<TMcpTask>;
    FLock: TCriticalSection;
    FPending: TDictionary<string, TMcpTask>;   // not answered yet, by Key
    // MCP roots: a client that has them is asked for them after the
    // handshake, and the load waits for the answer (ROOTS_WAIT_MS at most).
    // Settled once, under FLock: the workspace chosen and its load started.
    FRootWorkspace: TMcpRootWorkspace;
    FClientRoots: Boolean;
    FRootsAsked: Integer;
    FSettled: Boolean;
    FSettledEvt: TEvent;
    procedure Settle(ANew: TMcpWorkspace; const ARoot, ANote: string);
    procedure AskRoots;
    procedure TakeRoots(AMsg: TJSONObject);
    procedure Reply(AId: TJSONValue; AResult: TJSONValue);
    procedure ReplyError(AId: TJSONValue; ACode: Integer; const AMsg: string);
    procedure Progress(const AToken: string; ACount: Integer;
      const AText: string);
    function Initialize(AParams: TJSONObject): TJSONObject;
    procedure Enqueue(AId: TJSONValue; AParams: TJSONObject);
    procedure Cancel(AParams: TJSONObject);
    procedure Execute;
    procedure RunCall(ATask: TMcpTask);
    procedure StartWork(ATask: TMcpTask);
    procedure RunFinish(ATask: TMcpTask);
    procedure Answer(ATask: TMcpTask; const AText: string; AIsError: Boolean);
  public
    constructor Create(AWs: TMcpWorkspace; ATransport: TMcpTransport);
    procedure Handle(const AJson: string);
    // Starts the executor and reads until stdin closes.
    procedure Run;
    // Set before Run when the project was looked for from the working
    // directory; nil keeps the workspace whatever the roots.
    property RootWorkspace: TMcpRootWorkspace write FRootWorkspace;
  end;

const
  // The newest revision this server was written against; an older one a
  // client asks for is echoed back, since tools/list and tools/call have not
  // changed shape across them.
  cMcpProtocolVersion = '2025-06-18';

implementation

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  PasMcp.Version,
  PasMcp.Log;

const
  // How long the load waits for the client's roots/list answer: a client
  // answers in milliseconds, one that never does costs this once.
  ROOTS_WAIT_MS = 3000;
  ROOTS_ID_PREFIX = 'pastree-roots-';

// A URI's path with its %XX escapes read as UTF-8 bytes. Not a URL query:
// `+` stays a plus, as a file name may have one.
function PercentDecoded(const AText: string): string;
var
  LBytes: TBytes;
  LI, LN: Integer;
begin
  SetLength(LBytes, Length(AText) * 3);
  LN := 0;
  LI := 1;
  while LI <= Length(AText) do
  begin
    if (AText[LI] = '%') and (LI + 2 <= Length(AText)) and
       CharInSet(AText[LI + 1], ['0'..'9', 'A'..'F', 'a'..'f']) and
       CharInSet(AText[LI + 2], ['0'..'9', 'A'..'F', 'a'..'f']) then
    begin
      LBytes[LN] := StrToInt('$' + Copy(AText, LI + 1, 2));
      Inc(LN);
      Inc(LI, 3);
      Continue;
    end;
    for var LB in TEncoding.UTF8.GetBytes(AText[LI]) do
    begin
      LBytes[LN] := LB;
      Inc(LN);
    end;
    Inc(LI);
  end;
  Result := TEncoding.UTF8.GetString(LBytes, 0, LN);
end;

{ ---- TMcpTask ------------------------------------------------------------------ }

destructor TMcpTask.Destroy;
begin
  Id.Free;
  Args.Free;
  Job.Free;
  inherited;
end;

{ ---- TMcpServer ---------------------------------------------------------------- }

constructor TMcpServer.Create(AWs: TMcpWorkspace; ATransport: TMcpTransport);
begin
  inherited Create;
  FWs := AWs;
  FTransport := ATransport;
  // Deep enough never to block the reader: a client has a handful of calls
  // in flight at most.
  FQueue := TThreadedQueue<TMcpTask>.Create(10000, INFINITE, INFINITE);
  FLock := TCriticalSection.Create;
  FPending := TDictionary<string, TMcpTask>.Create;
  FSettledEvt := TEvent.Create(nil, True, False, '');
end;

// The workspace the calls use from now on - ANew, or the one the server was
// started with when nil - told the session's directory, and its load
// started. Once; a later call frees ANew. From the reader (the roots answer,
// a client without roots) or the executor (no answer in time).
procedure TMcpServer.Settle(ANew: TMcpWorkspace; const ARoot, ANote: string);
var
  LWs: TMcpWorkspace;
begin
  FLock.Enter;
  try
    if FSettled then
    begin
      ANew.Free;
      Exit;
    end;
    FSettled := True;
    // The one the server was started with is left as it is: `initialize`'s
    // instructions were written from it.
    if ANew <> nil then
      FWs := ANew;
    if ARoot <> '' then
      FWs.SetClientRoot(ARoot, ANote);
    LWs := FWs;
  finally
    FLock.Leave;
  end;
  TThread.CreateAnonymousThread(
    procedure
    begin
      LWs.Load;
    end).Start;
  FSettledEvt.SetEvent;
end;

procedure TMcpServer.AskRoots;
begin
  Inc(FRootsAsked);
  FTransport.WriteMessage(Format('{"jsonrpc":"2.0","id":"%s%d","method":'
    + '"roots/list"}', [ROOTS_ID_PREFIX, FRootsAsked]));
end;

// On the reader: the client's answer to roots/list. Its first file root is
// the session's directory.
procedure TMcpServer.TakeRoots(AMsg: TJSONObject);
var
  LRoots: TJSONValue;
  LUri, LDir, LAll, LNote: string;
  LNew: TMcpWorkspace;
begin
  LDir := '';
  LAll := '';
  LRoots := AMsg.FindValue('result.roots');
  if LRoots is TJSONArray then
    for var LRoot in TJSONArray(LRoots) do
    begin
      LUri := LRoot.GetValue<string>('uri', '');
      LAll := LAll + IfThen(LAll <> '', ', ') + LUri;
      if (LDir = '') and StartsText('file://', LUri) then
      begin
        // file:///C:/Repos/x%20y -> C:\Repos\x y; file://host/share ->
        // \\host\share. Claude Code 2.1 writes file://C:\Repos\x, a path
        // after the scheme as it is.
        LDir := PercentDecoded(Copy(LUri, 8, MaxInt));
        if (Length(LDir) >= 3) and (LDir[1] = '/') and (LDir[3] = ':') then
          Delete(LDir, 1, 1)
        else if (LDir <> '') and (LDir[1] <> '/') and
           not ((Length(LDir) >= 2) and (LDir[2] = ':')) then
          LDir := '//' + LDir;
        LDir := ExcludeTrailingPathDelimiter(LDir.Replace('/', '\'));
      end;
    end;
  if AMsg.GetValue('error') <> nil then
    Log('roots/list: the client answered with an error: %s', [AMsg.GetValue(
      'error').ToJSON])
  else
    Log('roots/list: %s', [IfThen(LAll <> '', LAll, 'none')]);
  if FSettled then
  begin
    if LDir <> '' then
      Log('the client''s root %s came after the load started - the server '
        + 'keeps %s', [LDir, FWs.ProjectFile]);
    Exit;
  end;
  LNew := nil;
  LNote := '';
  if (LDir <> '') and Assigned(FRootWorkspace) then
  try
    LNew := FRootWorkspace(LDir, LNote);
  except
    on E: Exception do
      Log('the client''s root %s: %s: %s', [LDir, E.ClassName, E.Message]);
  end;
  Settle(LNew, LDir, LNote);
end;

procedure TMcpServer.Reply(AId: TJSONValue; AResult: TJSONValue);
var
  LMsg: TJSONObject;
begin
  LMsg := TJSONObject.Create;
  try
    LMsg.AddPair('jsonrpc', '2.0');
    LMsg.AddPair('id', AId.Clone as TJSONValue);
    LMsg.AddPair('result', AResult);
    FTransport.WriteMessage(LMsg.ToJSON);
  finally
    LMsg.Free;
  end;
end;

procedure TMcpServer.ReplyError(AId: TJSONValue; ACode: Integer;
  const AMsg: string);
var
  LMsg, LErr: TJSONObject;
begin
  LMsg := TJSONObject.Create;
  try
    LMsg.AddPair('jsonrpc', '2.0');
    if AId <> nil then
      LMsg.AddPair('id', AId.Clone as TJSONValue)
    else
      LMsg.AddPair('id', TJSONNull.Create);
    LErr := TJSONObject.Create;
    LErr.AddPair('code', TJSONNumber.Create(ACode));
    LErr.AddPair('message', AMsg);
    LMsg.AddPair('error', LErr);
    FTransport.WriteMessage(LMsg.ToJSON);
  finally
    LMsg.Free;
  end;
end;

// From the thread doing a deferred tool's work. AToken is the token as the
// client wrote it (JSON), `progress` must increase with every notification,
// and there is no total to give.
procedure TMcpServer.Progress(const AToken: string; ACount: Integer;
  const AText: string);
var
  LText: TJSONString;
  LJson: string;
begin
  LText := TJSONString.Create(AText);
  try
    LJson := LText.ToJSON;
  finally
    LText.Free;
  end;
  FTransport.WriteMessage('{"jsonrpc":"2.0","method":"notifications/progress",'
    + '"params":{"progressToken":' + AToken + ',"progress":' + IntToStr(ACount)
    + ',"message":' + LJson + '}}');
end;

function TMcpServer.Initialize(AParams: TJSONObject): TJSONObject;
var
  LVersion, LNames: string;
  LCaps, LTools, LInfo: TJSONObject;
  LV: TJSONValue;
begin
  LVersion := cMcpProtocolVersion;
  if AParams <> nil then
    LVersion := AParams.GetValue<string>('protocolVersion', LVersion);
  if LVersion > cMcpProtocolVersion then
    LVersion := cMcpProtocolVersion;
  Result := TJSONObject.Create;
  Result.AddPair('protocolVersion', LVersion);
  LCaps := TJSONObject.Create;
  LTools := TJSONObject.Create;
  LTools.AddPair('listChanged', TJSONBool.Create(False));
  LCaps.AddPair('tools', LTools);
  Result.AddPair('capabilities', LCaps);
  LInfo := TJSONObject.Create;
  LInfo.AddPair('name', 'pastree');
  LInfo.AddPair('version', PasTreeMcpVersion);
  Result.AddPair('serverInfo', LInfo);
  Result.AddPair('instructions', ServerInstructions(FWs));
  LNames := '';
  if AParams <> nil then
  begin
    LV := AParams.GetValue('capabilities');
    if LV is TJSONObject then
      for var LPair in TJSONObject(LV) do
        LNames := LNames + IfThen(LNames <> '', ', ') + LPair.JsonString.Value;
    FClientRoots := (LV is TJSONObject) and (TJSONObject(LV).GetValue('roots')
      <> nil);
    Log('initialize from %s %s, protocol %s, client capabilities: %s', [
      AParams.GetValue<string>('clientInfo.name', '?'), AParams.GetValue<string>(
      'clientInfo.version', ''), LVersion, IfThen(LNames <> '', LNames,
      'none')]);
  end;
  // No roots to wait for: the load starts now.
  if not FClientRoots then
    Settle(nil, '', '');
end;

// On the reader: the call, cloned out of the message, into the queue.
procedure TMcpServer.Enqueue(AId: TJSONValue; AParams: TJSONObject);
var
  LTask: TMcpTask;
  LV, LToken: TJSONValue;
begin
  LTask := TMcpTask.Create;
  LTask.Kind := mtCall;
  LTask.Id := AId.Clone as TJSONValue;
  LTask.Key := AId.ToJSON;
  if AParams <> nil then
  begin
    LTask.Name := AParams.GetValue<string>('name', '');
    LV := AParams.GetValue('arguments');
    if LV is TJSONObject then
      LTask.Args := LV.Clone as TJSONObject;
    LV := AParams.GetValue('_meta');
    if LV is TJSONObject then
    begin
      LToken := TJSONObject(LV).GetValue('progressToken');
      if (LToken <> nil) and not (LToken is TJSONNull) then
        LTask.Token := LToken.ToJSON;
    end;
  end;
  FLock.Enter;
  try
    FPending.AddOrSetValue(LTask.Key, LTask);
  finally
    FLock.Leave;
  end;
  FQueue.PushItem(LTask);
end;

// On the reader: notifications/cancelled. The task, queued or running, is
// marked; a deferred tool's work is told to stop.
procedure TMcpServer.Cancel(AParams: TJSONObject);
var
  LV: TJSONValue;
  LTask: TMcpTask;
begin
  if AParams = nil then
    Exit;
  LV := AParams.GetValue('requestId');
  if LV = nil then
    Exit;
  FLock.Enter;
  try
    if FPending.TryGetValue(LV.ToJSON, LTask) then
    begin
      LTask.Cancelled := True;
      if LTask.Job <> nil then
        LTask.Job.Cancel;
      Log('tools/call %s (request %s) cancelled by the client', [LTask.Name,
        LV.ToJSON]);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TMcpServer.Execute;
var
  LTask: TMcpTask;
begin
  // No call before the workspace is chosen: a call queued behind the roots
  // answer would run on the one about to be replaced.
  if FSettledEvt.WaitFor(ROOTS_WAIT_MS) <> wrSignaled then
  begin
    Log('no roots/list answer in %d ms - the project the server was started '
      + 'with', [ROOTS_WAIT_MS]);
    Settle(nil, '', '');
  end;
  while FQueue.PopItem(LTask) = wrSignaled do
  begin
    if LTask = nil then
      Break;
    try
      if LTask.Kind = mtCall then
        RunCall(LTask)
      else
        RunFinish(LTask);
    except
      on E: Exception do
        Log('executor: %s raised %s: %s', [LTask.Name, E.ClassName,
          E.Message]);
    end;
  end;
end;

procedure TMcpServer.RunCall(ATask: TMcpTask);
var
  LText, LToken: string;
  LIsError, LSkip: Boolean;
  LJob: TDeferredTool;
  LProgress: TProc<string>;
  LCount: Integer;
begin
  FLock.Enter;
  try
    LSkip := ATask.Cancelled;
  finally
    FLock.Leave;
  end;
  if LSkip then
  begin
    Answer(ATask, '', False);   // not answered: only taken off the list
    ATask.Free;
    Exit;
  end;
  LProgress := nil;
  if ATask.Token <> '' then
  begin
    if ATask.Name = 'compile' then
      Log('tools/call %s: the client takes progress notifications',
        [ATask.Name]);
    LToken := ATask.Token;
    LCount := 0;
    LProgress :=
      procedure(AText: string)
      begin
        Inc(LCount);
        Progress(LToken, LCount, AText);
      end;
  end;
  // notifications/cancelled reaches a running call too: the workspace
  // queries completing an answer in light mode poll it (from a rebuild's
  // worker threads as well - read under the lock) and answer with what is
  // analyzed; the answer is then dropped as any cancelled one is.
  LText := CallTool(FWs, ATask.Name, ATask.Args, LIsError, LJob, LProgress,
    function: Boolean
    begin
      FLock.Enter;
      try
        Result := ATask.Cancelled;
      finally
        FLock.Leave;
      end;
    end);
  if LJob = nil then
  begin
    Answer(ATask, LText, LIsError);
    ATask.Free;
    Exit;
  end;
  FLock.Enter;
  try
    ATask.Job := LJob;
    ATask.Kind := mtFinish;
    // Cancelled while the call ran: the work stops as soon as it starts.
    if ATask.Cancelled then
      LJob.Cancel;
  finally
    FLock.Leave;
  end;
  StartWork(ATask);
end;

// A deferred tool's work on a thread of its own; its Finish back through the
// queue, done or not.
procedure TMcpServer.StartWork(ATask: TMcpTask);
begin
  TThread.CreateAnonymousThread(
    procedure
    begin
      try
        ATask.Job.Work;
      except
        on E: Exception do
          Log('tool %s: its work raised %s: %s', [ATask.Name, E.ClassName,
            E.Message]);
      end;
      FQueue.PushItem(ATask);
    end).Start;
end;

procedure TMcpServer.RunFinish(ATask: TMcpTask);
var
  LText: string;
  LIsError, LCancelled: Boolean;
begin
  FLock.Enter;
  try
    LCancelled := ATask.Cancelled;
  finally
    FLock.Leave;
  end;
  LText := '';
  LIsError := False;
  if not LCancelled then
  try
    LText := ATask.Job.Finish(LIsError);
  except
    on E: Exception do
    begin
      LIsError := True;
      LText := 'internal error: ' + E.ClassName + ': ' + E.Message;
      Log('tool %s raised %s: %s', [ATask.Name, E.ClassName, E.Message]);
    end;
  end;
  Answer(ATask, LText, LIsError);
  // Off the list now, so the reader cannot reach its job any more.
  ATask.Free;
end;

// Takes the task off the list and answers it - unless it was cancelled.
procedure TMcpServer.Answer(ATask: TMcpTask; const AText: string;
  AIsError: Boolean);
var
  LCancelled: Boolean;
  LResult, LItem: TJSONObject;
  LContent: TJSONArray;
begin
  FLock.Enter;
  try
    LCancelled := ATask.Cancelled;
    FPending.Remove(ATask.Key);
  finally
    FLock.Leave;
  end;
  if LCancelled then
  begin
    Log('tools/call %s: cancelled - not answered', [ATask.Name]);
    Exit;
  end;
  LResult := TJSONObject.Create;
  LContent := TJSONArray.Create;
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'text');
  LItem.AddPair('text', AText);
  LContent.AddElement(LItem);
  LResult.AddPair('content', LContent);
  LResult.AddPair('isError', TJSONBool.Create(AIsError));
  Reply(ATask.Id, LResult);
end;

procedure TMcpServer.Handle(const AJson: string);
var
  LMsg: TJSONValue;
  LObj, LParams: TJSONObject;
  LId, LP: TJSONValue;
  LMethod: string;
begin
  LMsg := TJSONObject.ParseJSONValue(AJson);
  try
    if not (LMsg is TJSONObject) then
    begin
      ReplyError(nil, -32700, 'parse error');
      Exit;
    end;
    LObj := TJSONObject(LMsg);
    LId := LObj.GetValue('id');
    LMethod := LObj.GetValue<string>('method', '');
    LP := LObj.GetValue('params');
    if LP is TJSONObject then
      LParams := TJSONObject(LP)
    else
      LParams := nil;
    if LId = nil then
    begin
      // A notification: initialized asks for the roots (a client may send
      // no request before it), cancelled stops a request.
      if LMethod = 'notifications/cancelled' then
        Cancel(LParams)
      else if (LMethod = 'notifications/initialized') and FClientRoots then
        AskRoots
      else if LMethod = 'notifications/roots/list_changed' then
      begin
        Log('the client''s roots changed - asked again; the project stays');
        AskRoots;
      end;
      Exit;
    end;
    // A response: to roots/list, the one request this server sends.
    if (LMethod = '') and ((LObj.GetValue('result') <> nil) or
       (LObj.GetValue('error') <> nil)) then
    begin
      if StartsStr(ROOTS_ID_PREFIX, LId.Value) then
        TakeRoots(LObj);
      Exit;
    end;
    try
      if LMethod = 'initialize' then
        Reply(LId, Initialize(LParams))
      else if LMethod = 'ping' then
        Reply(LId, TJSONObject.Create)
      else if LMethod = 'tools/list' then
        Reply(LId, TJSONObject.Create(TJSONPair.Create('tools',
          ToolDefinitions)))
      else if LMethod = 'tools/call' then
        Enqueue(LId, LParams)
      else
        ReplyError(LId, -32601, 'method not found: ' + LMethod);
    except
      on E: Exception do
      begin
        Log('%s raised %s: %s', [LMethod, E.ClassName, E.Message]);
        ReplyError(LId, -32603, E.Message);
      end;
    end;
  finally
    LMsg.Free;
  end;
end;

procedure TMcpServer.Run;
var
  LJson: string;
begin
  TThread.CreateAnonymousThread(Execute).Start;
  while FTransport.ReadMessage(LJson) do
    Handle(LJson);
  Log('stdin closed - shutting down');
end;

end.
