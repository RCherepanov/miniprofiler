unit miniprof;
{
  Встраиваемый профайлер MiniProfiler 1.53
-  Roman Cherepanov 2017.  x64 support added. 15.06.2017.
-  mailto: RCherepanov82@gmail.com
  Евгений Кацевман                  |
  Eugene Katsevman                  |
  2005-2006                         |
                                    |
  Aspi Soft, Kiev, Ukraine          |
  E-mail: aspi@i.kiev.ua            |
  http://miriada.com.ua             |
  Alexander Shlyahto                |
  Александр Шляхто                  |
                                    |
  2005                              |

  Использовано: Встраиваемый профайлер jDPro 1.01
                Mini-profiler for Delphi 1-7 , version 1.01
                Евгений Кацевман
                * Eugene Katsevman, 2005
                * mailto: jandor@yandex.ru , eugene.katsevman@gmail.com
Thanks to
       Rafail Ahmedishev - Рафаил Ахмедишев

}


interface
{$DEFINE MINI_PROFILER}



{$IFDEF MINI_PROFILER}

//Раскомментируйте для профилирования многопоточных приложений
//(замедляет профайлер на 20%)
{$DEFINE MINI_PROFILER_MULTITHREAD}

uses Windows, SysUtils, SyncObjs;

const
  PRECISION = 6; //Точность вывода

type
  strarr = class(TObject)
    cnt: Integer;
    str: array of string;
  private
    cap: Integer;
    procedure SetCap(aCap : integer);
  public
    constructor Create;
    procedure SaveToFile(FileName : string);
    procedure sort;
    procedure writeln(s : string; param : array of const);
  end;

  MiniProfiler = class(TObject)
  private
    class procedure CalcAverage_body(const RetAddr: pointer; const aName: string;
        aValue: Single);
    class procedure CalcMax_body(const RetAddr: pointer; const aName: string;
        aValue: Single);
    class procedure CalcMin_body(const RetAddr: pointer; const aName: string;
        aValue: Single);
    class procedure SectionBegin_body(const RetAddr: pointer; const aName: string);
  public
    class procedure CalcAverage(const aName: string; aValue: Single);
    class function GetTime(const aName: string): Int64;
    class procedure CalcMax(const aName: string; aValue: Single);
    class procedure CalcMin(const aName: string; aValue: Single);
    class procedure SaveToFile(aProfileFileName: string = 'profiler\profile';
        aValuesFileName: string = 'profiler\values');
    class procedure SectionBegin(const aName: string);
    class procedure SectionEnd;
  end;

  profiler = MiniProfiler;

{$ENDIF}
implementation


{$IFDEF MINI_PROFILER}

type

  PHashElement = ^RHashElement;
  RHashElement = record
    rNext: PHashElement;
    rReturnAddress: Pointer;
    rName: string;
    isSection: Boolean;
    case Integer of
      0: (rCallCount: Int64;
        rTotalTime: Int64;
        rMaxTime: Int64;
        rMinTime: Int64; );
      1: (rCount: Int64;
        rValue: Double;
        rDivide: Boolean);

  end;

  PStackElement = ^RStackElement;
  PPStackElement = ^PStackElement;
  RStackElement = record
    rPrior: PStackElement;
    rSectionAddress: PHashElement;
    rStartTime: Int64;
  end;

  PStackHashElement= ^TStackHashElement;

  TStackHashElement = record
    ID: Integer;
    next: PStackHashElement;
    pStack: PStackElement;
  end;

var
  //SecBegStack: PStackElement;
  HashSecAdrTbl: array[0..255] of PHashElement;
  HashThreadIDTbl: array[0..255] of PStackHashElement;
  path:PAnsiChar;
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock: TCriticalSection;
{$ENDIF}



function GetStackForThread: PPStackElement;
var
  I,ID: Integer;
  P:PStackHashElement;

begin
  ID:=GetCurrentThreadId;
  I := ID and $FF;
  P :=  HashThreadIDTbl[I];
  while P <> nil do
  begin

    if P.ID=ID then
    begin
    Result:=@P.pStack;
    Exit;
    end;
   P:=P.next;
  end;
  // Не нашли такой адрес -создаем элемент хеша
  New(P);
  P.ID:=ID;
  P.pStack:=nil;
  P.next := HashThreadIDTbl[I];
  HashThreadIDTbl[I] := P;
  Result:=@P.pStack;
//  Result:=@SecBegStack;
end;





function FindSectionByName(aAddress: string; Section: Boolean): PHashElement;
var
//{$IFDEF CPUX64}
//  I : Int64;
//{$ELSE}
  I : Integer;
//{$ENDIF}
begin
  for I := 0 to High(HashSecAdrTbl) do
  begin
    Result := HashSecAdrTbl[I];
    while Result <> nil do
    begin
      if Result.rName = aAddress then
        Exit;

      Result := Result.rNext;
    end;
  end;
  // Не нашли такой адрес -создаем элемент хеша
  Result := nil;
end;
function FindOrCreateSection(aAddress: Pointer; Section: Boolean): PHashElement;
var
{$IFDEF CPUX64}
  I : Int64;
{$ELSE}
  I : Integer;
{$ENDIF}
begin
{$IFDEF CPUX64}
  I := Int64(aAddress) and $FF;
{$ELSE}
  I := Integer(aAddress) and $FF;
{$ENDIF}
  Result := HashSecAdrTbl[I];
  while Result <> nil do
  begin
    if Result.rReturnAddress = aAddress then
      Exit;

    Result := Result.rNext;
  end;
  // Не нашли такой адрес -создаем элемент хеша
  New(Result);
  FillChar(Result^,sizeof(Result^),0);
  Result.rReturnAddress := aAddress;
  Result.isSection := Section; // тип
  Result.rNext := HashSecAdrTbl[I];
  HashSecAdrTbl[I] := Result;

end;

{
********************************* MiniProfiler *********************************
}
  function GetNextCodeAddress: pointer; //inline;
  // Получение адреса кода, следующего за вызовом метода SectionBegin
  // с учетом наличия/отсутствия инлайнинга в SectionBegin
  asm

   {$IFDEF CPUX64}
    .NOFRAME     // this is "leaf" function, no need of stack management
    MOV RCX, [RSP + $58 ]  // // i don't know, why $58 here, but next code adress is placed on this offset on stack.
    MOV Result, RCX
   {$ELSE CPUX64}
    MOV ECX, [ESP + $18]
    MOV Result, ECX
    //  or single instrucion      MOV EAX, [EBP+4]
   {$ENDIF}
  end;
class procedure MiniProfiler.CalcAverage(const aName: string; aValue: Single);
var
  RetAddr: Pointer;
begin
  // Получение адреса кода, следующего за вызовом этого метода
  RetAddr := GetNextCodeAddress;
  // вынесено в отдельный метод, ибо RAD Studio XE не позволяет
  // ассемблерные вставки в x64 mode. с ними код короче, но увы...

  CalcAverage_body(RetAddr, aName, aValue);

end;

class procedure MiniProfiler.CalcAverage_body(const RetAddr: pointer; const
    aName: string; aValue: Single);
var
  HashElement: PHashElement;
begin
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
  try
{$ENDIF}
    HashElement := FindOrCreateSection(RetAddr, False);
    with HashElement^ do
    begin
      rName := aName;
      Inc(rCount);
      rDivide := True;
      if rCount = 1 then
        rValue := aValue
      else
        rValue := rValue + aValue;
    end;

{$IFDEF MINI_PROFILER_MULTITHREAD}
  finally
    ProfLock.Leave;
  end;
{$ENDIF}
end;

class function MiniProfiler.GetTime(const aName: string): Int64;
var
  HashElement: PHashElement;
  freq: Int64;
begin
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
  try
{$ENDIF}
    QueryPerformanceFrequency(Freq);
    HashElement := FindSectionByName(aName, False);
    if HashElement <> nil
    then
      result := (HashElement^.rTotalTime*1000) div freq
    else
      result := 0;

{$IFDEF MINI_PROFILER_MULTITHREAD}
  finally
    ProfLock.Leave;
  end;
{$ENDIF}
end;

class procedure MiniProfiler.CalcMax(const aName: string; aValue: Single);
var
  RetAddr: Pointer;
begin
  // Получение адреса кода, следующего за вызовом этого метода
  RetAddr := GetNextCodeAddress;
  // вынесено в отдельный метод, ибо RAD Studio XE не позволяет
  // ассемблерные вставки в x64 mode. с ними код короче, но увы...

  CalcMax_body(RetAddr, aName, aValue);
end;

class procedure MiniProfiler.CalcMax_body(const RetAddr: pointer; const aName:
    string; aValue: Single);
var
  HashElement: PHashElement;
begin
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
  try
{$ENDIF}
    HashElement := FindOrCreateSection(RetAddr, False);
    with HashElement^ do
    begin
      rName := aName;
      Inc(rCount);
      rDivide := False;
      if rCount = 1 then
        rValue := aValue
      else if rValue < aValue then
        rValue := aValue;
    end;
{$IFDEF MINI_PROFILER_MULTITHREAD}
  finally
    ProfLock.Leave;
  end;
{$ENDIF}
end;

class procedure MiniProfiler.CalcMin(const aName: string; aValue: Single);
var
  RetAddr: Pointer;
  HashElement: PHashElement;
begin
  RetAddr := nil;
  // Получение адреса кода, следующего за вызовом этого метода

  // Получение адреса кода, следующего за вызовом этого метода
  RetAddr := GetNextCodeAddress;
  // вынесено в отдельный метод, ибо RAD Studio XE не позволяет
  // ассемблерные вставки в x64 mode. с ними код короче, но увы...


{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
  try
{$ENDIF}
    HashElement := FindOrCreateSection(RetAddr, False);
    with HashElement^ do
    begin
      rName := aName;
      Inc(rCount);
      rDivide := False;
      if rCount = 1 then
        rValue := aValue
      else if rValue > aValue then
        rValue := aValue;
    end;
{$IFDEF MINI_PROFILER_MULTITHREAD}
  finally
    ProfLock.Leave;
  end;
{$ENDIF}
end;

class procedure MiniProfiler.CalcMin_body(const RetAddr: pointer; const aName:
    string; aValue: Single);
var
  HashElement: PHashElement;
begin
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
  try
{$ENDIF}
    HashElement := FindOrCreateSection(RetAddr, False);
    with HashElement^ do
    begin
      rName := aName;
      Inc(rCount);
      rDivide := False;
      if rCount = 1 then
        rValue := aValue
      else if rValue > aValue then
        rValue := aValue;
    end;
{$IFDEF MINI_PROFILER_MULTITHREAD}
  finally
    ProfLock.Leave;
  end;
{$ENDIF}
end;

class procedure MiniProfiler.SaveToFile(aProfileFileName: string =
    'profiler\profile'; aValuesFileName: string = 'profiler\values');
var
  I: Integer;
  Freq: Int64;
  maxlenp, maxlenv: Integer;
  p: PHashElement;
  str1, str2 : strarr;
  NowStr : string;

  function GetUniqName(fName : string):string;
  var name,ext: string;
      i : integer;
      l : integer;
      flag : boolean;
  begin
    if FileExists(fName)
    then begin

      l := length(fNAme);
      flag := true;
      name := '';
      ext := '';
      for i := l downto 1 do
      begin
        if flag
        then begin
          if fName[i]<>'.'
          then  ext := fName[i]+ext
          else  flag := false
        end
        else  name := fName[i]+name;
      end;
      i := 0;
      repeat
        result := format('%s%3.3u.%s', [Name, i, Ext]) ;
        inc(i);
      until not (FileExists(result));
    end
    else
      result := fName;
  end;



  function calcMaxLen(Section: Boolean): Integer;
  var
    i: Integer;
    p: PHashElement;
  begin
    Result := 0;
    for i := 0 to 255 do
    begin
      p := HashSecAdrTbl[i];
      while p <> nil do
      begin
        if (p.isSection = Section) and (length(p.rName) > Result) then
          Result := length(p.rName);
        p := p.rNext;
      end;
    end;
  end;

begin
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
  try
{$ENDIF}
    str1 := strarr.Create;
    str2 := strarr.Create;

 //   OldDecSep := DecimalSeparator;
 //   DecimalSeparator := '.';
    try
      QueryPerformanceFrequency(Freq);
      maxlenp := calcMaxLen(True);
      maxlenv := calcMaxLen(False);

      NowStr := format('%*s', [maxlenp+30,DateTimeToStr(now)]);
      str1.writeln(NowStr, []);
      str1.writeln('%*s | Call Count | %15s | %16s | %16s | %16s |',
                             [  maxLenp, 'Name',
                                'Total time (s)',
                                'Average time (s)',
                                'Max time (s)',
                                'Min time (s)']
                   );

     str2.writeln(NowStr, []);
     str2.writeln('%*s Value', [maxlenv, 'Name']);
      for I := 0 to 255 do
      begin
        p := HashSecAdrTbl[i];
        while p <> nil do
        begin
          with p^ do
            if isSection then
            begin
              if (rCallCount <> 0) then
                {writeln(FP, rName: maxlenp, ' ', rCallCount: 10,
                  ' ', rTotalTime /
                  freq: 15: PRECISION
                  , ' ',
                  rTotalTime / rCallCount / freq: 16: PRECISION
                  , ' ',
                  rMaxTime / freq: 16: PRECISION
                  , ' ',
                  rMinTime / freq: 16: PRECISION); }
                str1.writeln('%-*s | %10d | %15.*f | %16.*f | %16.*f | %16.*f |',
                [maxlenp,  rName,
                           rCallCount,
                PRECISION, rTotalTime/freq,
                PRECISION, rTotalTime / rCallCount / freq,
                PRECISION, rMaxTime / freq,
                PRECISION, rMinTime / freq
                ] )

            end
            else if rDivide then
              str2.writeln('%*s %16.*f', [maxlenv, rName, PRECISION, rValue / rCount ])
            else
              str2.writeln('%*s %16.*f', [maxlenv, rName, PRECISION, rValue ]);
          p := p.rNext;
        end;
      end;

    finally
//      DecimalSeparator := OldDecSep;
      str1.sort;
      str2.sort;
      str1.SaveToFile(GetUniqName(aProfileFileName));
      str2.SaveToFile(GetUniqName(aValuesFileName));
      str1.Free;
      str2.Free;
    end;

{$IFDEF MINI_PROFILER_MULTITHREAD}
  finally
    ProfLock.Leave;
  end;
{$ENDIF}
end;

class procedure MiniProfiler.SectionBegin(const aName: string);
var
  RetAddr: Pointer;
begin
  // Получение адреса кода, следующего за вызовом этого метода
  RetAddr := GetNextCodeAddress;
  // вынесено в отдельный метод, ибо RAD Studio XE не позволяет
  // ассемблерные вставки в x64 mode. с ними код короче, но увы...
  SectionBegin_body(RetAddr, aName);
end;

class procedure MiniProfiler.SectionBegin_body(const RetAddr: pointer; const
    aName: string);
var
  StackElement: PStackElement;
  HashElement: PHashElement;
  SecBegStack:PPStackElement;
begin
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
  try
{$ENDIF}

    //поиск в хеше
    HashElement := FindOrCreateSection(RetAddr, True);
    with HashElement^ do
    begin
      rName := aName;
      Inc(rCallCount);
    end;
    New(StackElement);
    SecBegStack:=GetStackForThread;
    with StackElement^ do
    begin
      rSectionAddress := HashElement;
      rPrior := SecBegStack^;
      SecBegStack^ := StackElement;
//      LogWriteln(SecBegStack^.rSectionAddress.rName+' entered');
      QueryPerformanceCounter(StackElement.rStartTime);
    end
{$IFDEF MINI_PROFILER_MULTITHREAD}
  finally
    ProfLock.Leave;
  end;
{$ENDIF}
end;

class procedure MiniProfiler.SectionEnd;
var
  SE: PStackElement;
  EndTime: Int64;
  Diff: Int64;
  SecBegStack:PPStackElement;
begin
  QueryPerformanceCounter(EndTime);
  SecBegStack:=GetStackForThread;
  if Assigned(SecBegStack^) then
  begin
{$IFDEF MINI_PROFILER_MULTITHREAD}
    ProfLock.Enter;
    try
{$ENDIF}

      with SecBegStack^.rSectionAddress^ do
      begin
        Diff := EndTime - SecBegStack^.rStartTime;
        Inc(rTotalTime, Diff);
        if rCallCount = 1 then
        begin
          rMinTime := Diff;
          rMaxTime := Diff;
        end
        else
        begin
          if rMaxTime < Diff then
            rMaxTime := Diff;
          if rMinTime > Diff then
            rMinTime := Diff;
        end;
      end;

      SE := SecBegStack^.rPrior;
//      LogWriteln(SecBegStack^.rSectionAddress.rName+' exited');
      Dispose(SecBegStack^);
      SecBegStack^ := SE;
{$IFDEF MINI_PROFILER_MULTITHREAD}
    finally
      ProfLock.Leave;
    end;
{$ENDIF}
  end;
end;

procedure DisposeHashAdrTbl;
var
  Tmp, Cur: PHashElement;
  I: Integer;
begin
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
  try
{$ENDIF}
    for I := Low(HashSecAdrTbl) to High(HashSecAdrTbl) do
    begin
      Cur := HashSecAdrTbl[I];
      while Assigned(Cur) do
      begin
        Tmp := Cur.rNext;
        Dispose(Cur);
        Cur := Tmp;
      end;
    end;
{$IFDEF MINI_PROFILER_MULTITHREAD}
  finally
    ProfLock.Leave;
  end;
{$ENDIF}
end;

procedure DisposeHashThreadIDTbl;
var
  Tmp, Cur: PStackHashElement;
  I: Integer;

procedure PopStack(p:PStackElement);

var
  SE: PStackElement;
  EndTime: Int64;
  Diff: Int64;
begin
  QueryPerformanceCounter(EndTime);
  while Assigned(p) do
  begin
      with p.rSectionAddress^ do
      begin
        Diff := EndTime - p.rStartTime;
        Inc(rTotalTime, Diff);
        if rCallCount = 1 then
        begin
          rMinTime := Diff;
          rMaxTime := Diff;
        end
        else
        begin
          if rMaxTime < Diff then
            rMaxTime := Diff;
          if rMinTime > Diff then
            rMinTime := Diff;
        end;
      end;

//      LogWriteln(p.rSectionAddress.rName+' exited at finalization');
      SE := p.rPrior;
      Dispose(p);
      p := SE;
  end;
end;


begin
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
  try
{$ENDIF}
    for I := Low(HashThreadIDTbl) to High(HashThreadIDTbl) do
    begin
      Cur := HashThreadIDTbl[I];
      while Assigned(Cur) do
      begin
        Tmp := Cur.next;

        PopStack(Cur.pStack);
        Dispose(Cur);


        Cur := Tmp;
      end;
    end;
{$IFDEF MINI_PROFILER_MULTITHREAD}
  finally
    ProfLock.Leave;
  end;
{$ENDIF}
end;




{
************************************ strarr ************************************
}
constructor strarr.Create;
begin
  cnt :=  0;
  setCap(10);
end;

procedure strarr.SaveToFile(FileName : string);
var i : integer;
    f : textfile;
begin
  assignFile(f, FileName);
  rewrite(f);
  for i := 0 to high(str) {cnt-1} do
    system.writeln(f, str[i]);

  closefile(f);
end;

procedure strarr.SetCap(aCap : integer);
begin
  cap := aCap;
  setLength(str, cap);
end;

procedure strarr.sort;
var i,j : integer;
    sss : string;
begin
  for j := cnt-1 downto 1 do
  for i := 0 to j-1 do
  begin
    if str[i]>str[i+1]
    then begin
      sss := str[i];
      str[i]:= str[i+1];
      str[i+1] := sss;
    end;
  end;
end;

procedure strarr.writeln(s : string; param : array of const);
begin
  str[cnt] := format(s, param);
  inc(cnt);

  if cnt > cap-3
  then
    setCap(cap+10);

end;

{ strarr }

initialization
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock := TCriticalSection.Create;
{$ENDIF}


finalization
{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Enter;
{$ENDIF}

//  while Assigned(SecBegStack) do
//    MiniProfiler.SectionEnd;
  getmem(path,256);
  {$IFDEF VER150}
    GetModuleFilename(hInstance, path ,256);
  {$ELSE}
    GetModuleFilename(hInstance,PWideChar(path),256);
  {$ENDIF}
  MiniProfiler.SaveToFile(ExtractFilePath(path)+'profiler\profile.txt',
                          ExtractFilePath(path)+'profiler\values.txt');
// убиваем все стеки
  DisposeHashThreadIDTbl;
  DisposeHashAdrTbl;

{$IFDEF MINI_PROFILER_MULTITHREAD}
  ProfLock.Leave;
  ProfLock.Free;
{$ENDIF}
{$ENDIF}
  freemem(path, 256); // needed becouse of FastMM memory leak warning.
end.

