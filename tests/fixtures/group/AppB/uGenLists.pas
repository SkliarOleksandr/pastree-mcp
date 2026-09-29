unit uGenLists;

// A member reached through a generic ancestor's type parameter (field
// report FR.2): TItemList<T> redeclares its non-generic parent's GetRecord and
// Records with T, and TItemList<T, TL> derives from it - the shape of a
// record list family - so GetRecord(0).Code in a descendant is ICoded's,
// written bare, through Self, a variable or a `with`: dcc compiles each.

interface

type
  IItem = interface
    function GetId: Integer;
  end;

  ICoded = interface(IItem)
    function GetCode: string;
    property Code: string read GetCode;
  end;

  TItemList = class
  protected
    function GetRecord(AIndex: Integer): IItem;
  public
    property Records[AIndex: Integer]: IItem read GetRecord; default;
  end;

  TItemList<T: IItem> = class(TItemList)
  protected
    function GetRecord(AIndex: Integer): T;
  public
    property Records[AIndex: Integer]: T read GetRecord; default;
  end;

  TItemList<T: IItem; TL: class> = class(TItemList<T>)
  end;

  TCodedList = class(TItemList<ICoded>)
  public
    function FirstCode: string;
  end;

  TCodedPairList = class(TItemList<ICoded, TObject>)
  public
    function FirstCode: string;
    function SecondCode: string;
    function ThirdCode: string;
    function FourthCode: string;
  end;

function CodeOf(AList: TCodedList): string;
function GenericCodeOf(AList: TItemList<ICoded>): string;
function WithCode(AList: TCodedList): string;

implementation

function TItemList.GetRecord(AIndex: Integer): IItem;
begin
  Result := nil;
end;

function TItemList<T>.GetRecord(AIndex: Integer): T;
begin
  Result := Default(T);
end;

function TCodedList.FirstCode: string;
begin
  Result := GetRecord(0).Code;
end;

function TCodedPairList.FirstCode: string;
begin
  Result := GetRecord(0).Code;
end;

function TCodedPairList.SecondCode: string;
begin
  Result := Records[1].Code;
end;

function TCodedPairList.ThirdCode: string;
begin
  Result := Self[2].Code;
end;

function TCodedPairList.FourthCode: string;
begin
  Result := Self.GetRecord(3).Code;
end;

// From outside the class: through a variable of the descendant.
function CodeOf(AList: TCodedList): string;
begin
  Result := AList.GetRecord(0).Code;
end;

function GenericCodeOf(AList: TItemList<ICoded>): string;
begin
  Result := AList.GetRecord(0).Code;
end;

// A `with` over the descendant: its bare call has the instance's frame.
function WithCode(AList: TCodedList): string;
begin
  with AList do
    Result := GetRecord(0).Code;
end;

end.
