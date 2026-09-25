unit PasMcp.Transport;

{
  MCP stdio framing: one JSON-RPC message per line, UTF-8, '\n'-terminated,
  no embedded newlines (MCP spec, "Transports / stdio"). NOT the LSP framing -
  there are no Content-Length headers here, which is the one transport detail
  that differs from pastree-lsp.

  Reads the raw stdin handle rather than Readln: Readln decodes through the
  console code page, and a non-ASCII identifier in a request would arrive
  mangled. Writes go out as one WriteFile per message so a message is never
  interleaved with anything else.
}

interface

uses
  System.SysUtils;

type
  TMcpTransport = class
  private
    FIn, FOut: THandle;
    FBuf: TBytes;
    FLen: Integer;
    FEof: Boolean;
  public
    constructor Create;
    // Next non-empty line, or False at end of input (the client closed stdin -
    // the MCP way of saying "shut down").
    function ReadMessage(out AJson: string): Boolean;
    procedure WriteMessage(const AJson: string);
  end;

implementation

uses
  Winapi.Windows;

constructor TMcpTransport.Create;
begin
  inherited Create;
  FIn := GetStdHandle(STD_INPUT_HANDLE);
  FOut := GetStdHandle(STD_OUTPUT_HANDLE);
  SetLength(FBuf, 65536);
end;

function TMcpTransport.ReadMessage(out AJson: string): Boolean;
var
  LIdx, LLineEnd: Integer;
  LRead: DWORD;
begin
  AJson := '';
  while True do
  begin
    LLineEnd := -1;
    for LIdx := 0 to FLen - 1 do
      if FBuf[LIdx] = 10 then
      begin
        LLineEnd := LIdx;
        Break;
      end;
    if LLineEnd >= 0 then
    begin
      AJson := Trim(TEncoding.UTF8.GetString(FBuf, 0, LLineEnd));
      Move(FBuf[LLineEnd + 1], FBuf[0], FLen - LLineEnd - 1);
      Dec(FLen, LLineEnd + 1);
      if AJson <> '' then
        Exit(True);
      Continue;
    end;
    if FEof then
    begin
      // A last message with no trailing newline still counts.
      if FLen > 0 then
      begin
        AJson := Trim(TEncoding.UTF8.GetString(FBuf, 0, FLen));
        FLen := 0;
        Exit(AJson <> '');
      end;
      Exit(False);
    end;
    if FLen = Length(FBuf) then
      SetLength(FBuf, Length(FBuf) * 2);
    if not ReadFile(FIn, FBuf[FLen], Length(FBuf) - FLen, LRead, nil) or
       (LRead = 0) then
      FEof := True
    else
      Inc(FLen, LRead);
  end;
end;

procedure TMcpTransport.WriteMessage(const AJson: string);
var
  LBytes: TBytes;
  LWritten: DWORD;
  LPos: Integer;
begin
  LBytes := TEncoding.UTF8.GetBytes(AJson + #10);
  LPos := 0;
  while LPos < Length(LBytes) do
  begin
    if not WriteFile(FOut, LBytes[LPos], Length(LBytes) - LPos, LWritten, nil)
    then
      Exit;
    Inc(LPos, LWritten);
  end;
end;

end.
