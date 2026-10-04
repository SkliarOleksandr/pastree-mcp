unit uLintAlias;

// For `lint`: an alias under the name of what it names, as Vcl.Controls
// declares TModalResult = System.UITypes.TModalResult - the index binds
// uLint's IItem through to uGenLists, which uLint does not list.

interface

uses
  uGenLists, uLintReg;

type
  IItem = uGenLists.IItem;

implementation

end.
