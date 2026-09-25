unit PasMcp.Log;

{
  Logging for a process whose stdout belongs to the protocol.

  stdout carries MCP messages and NOTHING else - one stray line there and the
  client drops the connection with a parse error that names no cause. So every
  human-readable line goes to stderr (Claude Code keeps it in its MCP log) and,
  once SetLogFile has been called, to a file as well: the file is what a user
  sends in, stderr is what a developer watches.

  Thread-safe: the initial analysis logs from its own thread.
}

interface

procedure SetLogFile(const APath: string);
function LogFile: string;
procedure Log(const AText: string); overload;
procedure Log(const AFmt: string; const AArgs: array of const); overload;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Winapi.Windows;

var
  GLock: TCriticalSection;
  GFile: TFileStream;
  GFilePath: string;

procedure WriteStdErr(const ABytes: TBytes);
var
  LWritten: DWORD;
begin
  if Length(ABytes) > 0 then
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), ABytes[0], Length(ABytes),
      LWritten, nil);
end;

procedure SetLogFile(const APath: string);
begin
  GLock.Enter;
  try
    FreeAndNil(GFile);
    GFilePath := '';
    try
      // Truncated per run: one run, one log - a file that grows across
      // sessions buries the run a report is about.
      GFile := TFileStream.Create(APath, fmCreate or fmShareDenyWrite);
      GFilePath := APath;
    except
      on E: Exception do
        WriteStdErr(TEncoding.UTF8.GetBytes(
          'cannot open log file ' + APath + ': ' + E.Message + sLineBreak));
    end;
  finally
    GLock.Leave;
  end;
end;

function LogFile: string;
begin
  Result := GFilePath;
end;

procedure Log(const AText: string);
var
  LBytes: TBytes;
begin
  LBytes := TEncoding.UTF8.GetBytes(FormatDateTime('hh:nn:ss.zzz', Now) + ' ' +
    AText + sLineBreak);
  GLock.Enter;
  try
    WriteStdErr(LBytes);
    if GFile <> nil then
      GFile.WriteBuffer(LBytes[0], Length(LBytes));
  finally
    GLock.Leave;
  end;
end;

procedure Log(const AFmt: string; const AArgs: array of const);
begin
  Log(Format(AFmt, AArgs));
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  FreeAndNil(GFile);
  FreeAndNil(GLock);

end.
