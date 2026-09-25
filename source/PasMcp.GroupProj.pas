unit PasMcp.GroupProj;

{
  .groupproj reader: the member projects of a RAD Studio project group, in
  file order, as absolute paths.

  A .groupproj is MSBuild XML whose only content that matters here is
  `<Projects Include="relative\path.dproj">` inside an ItemGroup. Nothing else
  in the file (the per-member <Dependencies>, the build <Target>s) changes WHAT
  gets analyzed, so this reads the Include attributes and nothing more. PasTree's
  README names PasTree.DProj as the eventual home of a group reader; when it
  lands there, this unit goes.

  Members that do not exist on disk are returned too (AMissing), because a
  group opened on a machine without one of its projects is common and worth
  saying out loud rather than silently analyzing less.
}

interface

// False when the file cannot be read or holds no <Projects Include=...> item.
function ReadGroupProj(const APath: string; out AMembers,
  AMissing: TArray<string>): Boolean;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.StrUtils;

function ReadGroupProj(const APath: string; out AMembers,
  AMissing: TArray<string>): Boolean;
const
  TAG = '<Projects';
var
  LText, LLower, LInclude, LFull: string;
  LPos, LEnd, LAttr, LQuote: Integer;
  LQ: Char;
begin
  AMembers := nil;
  AMissing := nil;
  try
    LText := TFile.ReadAllText(APath);   // BOM-aware
  except
    Exit(False);
  end;
  LLower := LowerCase(LText);
  LPos := Pos(LowerCase(TAG), LLower);
  while LPos > 0 do
  begin
    LEnd := PosEx('>', LLower, LPos);
    if LEnd = 0 then
      Break;
    LAttr := PosEx('include', LLower, LPos);
    if (LAttr > 0) and (LAttr < LEnd) then
    begin
      LQuote := LAttr + Length('include');
      while (LQuote < LEnd) and not CharInSet(LText[LQuote], ['"', '''']) do
        Inc(LQuote);
      if LQuote < LEnd then
      begin
        LQ := LText[LQuote];
        LAttr := PosEx(LQ, LText, LQuote + 1);
        if LAttr > 0 then
        begin
          LInclude := Copy(LText, LQuote + 1, LAttr - LQuote - 1);
          LFull := TPath.GetFullPath(TPath.Combine(TPath.GetDirectoryName(
            TPath.GetFullPath(APath)), LInclude));
          if TFile.Exists(LFull) then
            AMembers := AMembers + [LFull]
          else
            AMissing := AMissing + [LFull];
        end;
      end;
    end;
    LPos := PosEx(LowerCase(TAG), LLower, LEnd);
  end;
  Result := (Length(AMembers) > 0) or (Length(AMissing) > 0);
end;

end.
