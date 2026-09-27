unit PasMcp.Server;

{
  The JSON-RPC side of MCP: initialize, ping, tools/list, tools/call.

  Deliberately the smallest server the protocol allows - tools only, no
  resources, prompts, sampling or subscriptions. `instructions` in the
  initialize result is the one extra: Claude Code puts it in front of the
  model, and it is where the model learns WHEN to reach for these tools
  instead of grep.

  Requests are answered in order, one at a time, on the calling thread. A
  tool call waits for the initial analysis (see PasMcp.Tools.CallTool); the
  handshake and `status` never do.

  A tools/call whose params carry `_meta.progressToken` gets
  notifications/progress while it runs, from a tool that reports
  (PasMcp.Tools.ToolProgress: `compile`). Claude Code aborts a call to a
  stdio server that sends neither a response nor a progress notification for
  30 minutes (its MCP documentation), so a notification keeps a long build
  alive, and the message shows what it is doing.
}

interface

uses
  System.JSON,
  PasMcp.Transport,
  PasMcp.Workspace;

type
  TMcpServer = class
  private
    FWs: TMcpWorkspace;
    FTransport: TMcpTransport;
    procedure Reply(AId: TJSONValue; AResult: TJSONValue);
    procedure ReplyError(AId: TJSONValue; ACode: Integer; const AMsg: string);
    procedure Progress(AToken: TJSONValue; ACount: Integer; const AText: string);
    function Initialize(AParams: TJSONObject): TJSONObject;
    function ToolsCall(AParams: TJSONObject): TJSONObject;
  public
    constructor Create(AWs: TMcpWorkspace; ATransport: TMcpTransport);
    procedure Handle(const AJson: string);
    // Reads until stdin closes.
    procedure Run;
  end;

const
  // The newest revision this server was written against; an older one a
  // client asks for is echoed back, since tools/list and tools/call have not
  // changed shape across them.
  cMcpProtocolVersion = '2025-06-18';

implementation

uses
  System.SysUtils,
  PasMcp.Version,
  PasMcp.Log,
  PasMcp.Tools;

constructor TMcpServer.Create(AWs: TMcpWorkspace; ATransport: TMcpTransport);
begin
  inherited Create;
  FWs := AWs;
  FTransport := ATransport;
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

procedure TMcpServer.Progress(AToken: TJSONValue; ACount: Integer;
  const AText: string);
var
  LMsg, LParams: TJSONObject;
begin
  LMsg := TJSONObject.Create;
  try
    LMsg.AddPair('jsonrpc', '2.0');
    LMsg.AddPair('method', 'notifications/progress');
    LParams := TJSONObject.Create;
    LParams.AddPair('progressToken', AToken.Clone as TJSONValue);
    // Must increase with every notification; there is no total to give.
    LParams.AddPair('progress', TJSONNumber.Create(ACount));
    LParams.AddPair('message', AText);
    LMsg.AddPair('params', LParams);
    FTransport.WriteMessage(LMsg.ToJSON);
  finally
    LMsg.Free;
  end;
end;

function TMcpServer.Initialize(AParams: TJSONObject): TJSONObject;
var
  LVersion: string;
  LCaps, LTools, LInfo: TJSONObject;
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
  if AParams <> nil then
    Log('initialize from %s, protocol %s', [AParams.GetValue<string>(
      'clientInfo.name', '?'), LVersion]);
end;

function TMcpServer.ToolsCall(AParams: TJSONObject): TJSONObject;
var
  LName, LText: string;
  LArgs: TJSONObject;
  LIsError: Boolean;
  LContent: TJSONArray;
  LItem: TJSONObject;
  LV, LToken: TJSONValue;
  LCount: Integer;
begin
  LName := '';
  LArgs := nil;
  LToken := nil;
  if AParams <> nil then
  begin
    LName := AParams.GetValue<string>('name', '');
    LV := AParams.GetValue('arguments');
    if LV is TJSONObject then
      LArgs := TJSONObject(LV);
    LV := AParams.GetValue('_meta');
    if LV is TJSONObject then
      LToken := TJSONObject(LV).GetValue('progressToken');
  end;
  LCount := 0;
  if (LToken <> nil) and not (LToken is TJSONNull) and (LName = 'compile') then
    Log('tools/call %s: the client takes progress notifications', [LName]);
  if (LToken <> nil) and not (LToken is TJSONNull) then
    ToolProgress :=
      procedure(AText: string)
      begin
        Inc(LCount);
        Progress(LToken, LCount, AText);
      end;
  try
    LText := CallTool(FWs, LName, LArgs, LIsError);
  finally
    ToolProgress := nil;
  end;
  Result := TJSONObject.Create;
  LContent := TJSONArray.Create;
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'text');
  LItem.AddPair('text', LText);
  LContent.AddElement(LItem);
  Result.AddPair('content', LContent);
  Result.AddPair('isError', TJSONBool.Create(LIsError));
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
      Exit;   // a notification: initialized, cancelled - nothing to answer
    try
      if LMethod = 'initialize' then
        Reply(LId, Initialize(LParams))
      else if LMethod = 'ping' then
        Reply(LId, TJSONObject.Create)
      else if LMethod = 'tools/list' then
        Reply(LId, TJSONObject.Create(TJSONPair.Create('tools',
          ToolDefinitions)))
      else if LMethod = 'tools/call' then
        Reply(LId, ToolsCall(LParams))
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
  while FTransport.ReadMessage(LJson) do
    Handle(LJson);
  Log('stdin closed - shutting down');
end;

end.
