object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'Main'
  ClientHeight = 160
  ClientWidth = 320
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  TextHeight = 15
  object lblName: TLabel
    Left = 8
    Top = 12
    Width = 32
    Height = 15
    Caption = '&Name'
    FocusControl = edtName
  end
  object edtName: TEdit
    Left = 56
    Top = 8
    Width = 177
    Height = 23
    TabOrder = 0
    OnChange = NameChange
  end
  object btnSave: TButton
    Left = 240
    Top = 7
    Width = 75
    Height = 25
    Caption = 'Save'
    PopupMenu = dmData.pmActions
    TabOrder = 1
    OnClick = btnSaveClick
  end
  inline fraName1: TfraName
    Left = 8
    Top = 48
    Width = 240
    Height = 40
    TabOrder = 2
    inherited btnClear: TButton
      OnClick = fraName1btnClearClick
    end
  end
end
  object btnGhost: TButton
    OnClick = NeverBound
  end
end
