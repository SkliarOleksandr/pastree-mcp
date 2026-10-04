unit uLintBase;

// For `lint`: TLintCount names this unit's in uLint's interface - uLintMore,
// in uLint's implementation `uses`, declares one too, and dcc does not search
// those units for the interface.

interface

uses
  uLintReg;

type
  TLintCount = Integer;

implementation

end.
