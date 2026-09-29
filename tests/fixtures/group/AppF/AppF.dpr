program AppF;

// A VCL member, a bare .dpr like AppB: forms whose .dfm files bind components
// and handlers by name, which no reference search of the Pascal sources sees
// (SPEC 9.5). The smoke test pins line numbers of its units and form files.

uses
  Vcl.Forms,
  uData in 'uData.pas' {dmData: TDataModule},
  uFrame in 'uFrame.pas' {fraName: TFrame},
  uMainForm in 'uMainForm.pas' {frmMain},
  uChildForm in 'uChildForm.pas' {frmChild},
  uPlainForm in 'uPlainForm.pas',
  uBinaryForm in 'uBinaryForm.pas' {frmBinary};

begin
  Application.Initialize;
  Application.CreateForm(TdmData, dmData);
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
