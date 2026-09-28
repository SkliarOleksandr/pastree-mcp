inherited frmChild: TfrmChild
  Caption = 'Child'
  TextHeight = 15
  inherited btnSave: TButton
    OnClick = ChildSaveClick
  end
  object chkConfirm: TCheckBox
    Left = 8
    Top = 104
    Width = 97
    Height = 17
    Caption = 'Confirm'
    TabOrder = 3
    OnClick = btnSaveClick
  end
  inherited edtName: TEdit
    OnChange = nil
  end
  object grpTools: TButtonGroup
    Items = <
      item
        OnClick = ChildSaveClick
      end
      item
        OnClick = btnSaveClick
      end>
  end
end
