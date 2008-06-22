//
//
//           The Nimrod Compiler
//        (c) Copyright 2008 Andreas Rumpf
//
//    See the file "copying.txt", included in this
//    distribution, for details about the copyright.
//
unit astalgo;

// Algorithms for the abstract syntax tree: hash tables, lists
// and sets of nodes are supported. Efficiency is important as
// the data structures here are used in the whole compiler.

interface

{$include 'config.inc'}

uses
  nsystem, ast, hashes, charsets, strutils, options, msgs, ropes, idents;

function hashNode(p: PObject): THash;

function treeToYaml(n: PNode; indent: int = 0; maxRecDepth: int = -1): PRope;
// Convert a tree into its YAML representation; this is used by the
// YAML code generator and it is invaluable for debugging purposes.
// If maxRecDepht <> -1 then it won't print the whole graph.

function typeToYaml(n: PType; indent: int = 0; maxRecDepth: int = -1): PRope;
function symToYaml(n: PSym; indent: int = 0; maxRecDepth: int = -1): PRope;
function optionsToStr(flags: TOptions): PRope;
function lineInfoToStr(const info: TLineInfo): PRope;

// ----------------------- node sets: ---------------------------------------

function ObjectSetContains(const t: TObjectSet; obj: PObject): Boolean;
// returns true whether n is in t

procedure ObjectSetIncl(var t: TObjectSet; obj: PObject);
// include an element n in the table t

function ObjectSetContainsOrIncl(var t: TObjectSet; obj: PObject): Boolean;

// more are not needed ...

// ----------------------- (key, val)-Hashtables ----------------------------

procedure TablePut(var t: TTable; key, val: PObject);
function TableGet(const t: TTable; key: PObject): PObject;

type
  TCmpProc = function (key, closure: PObject): Boolean;
  // should return true if found
function TableSearch(const t: TTable; key, closure: PObject;
                     comparator: TCmpProc): PObject;
// return val as soon as comparator returns true; if this never happens,
// nil is returned

// ----------------------- str table -----------------------------------------

function StrTableContains(const t: TStrTable; n: PSym): Boolean;
procedure StrTableAdd(var t: TStrTable; n: PSym);
function StrTableGet(const t: TStrTable; name: PIdent): PSym;
function StrTableIncl(var t: TStrTable; n: PSym): Boolean;
// returns true if n is already in the string table

// the iterator scheme:
type
  TTabIter = record // consider all fields here private
    h: THash; // current hash
  end;

function InitTabIter(out ti: TTabIter; const tab: TStrTable): PSym;
function NextIter(var ti: TTabIter; const tab: TStrTable): PSym;
// usage:
// var i: TTabIter; s: PSym;
// s := InitTabIter(i, table);
// while s <> nil do begin
//   ...
//   s := NextIter(i, table);
// end;


type
  TIdentIter = record // iterator over all syms with the same identifier
    h: THash; // current hash
    name: PIdent;
  end;

function InitIdentIter(out ti: TIdentIter; const tab: TStrTable;
  s: PIdent): PSym;
function NextIdentIter(var ti: TIdentIter; const tab: TStrTable): PSym;

// -------------- symbol table ----------------------------------------------

// Each TParser object (which represents a module being compiled) has its own
// symbol table. A symbol table is organized as a stack of str tables. The
// stack represents the different scopes.
// Stack pointer:
// 0                imported symbols from other modules
// 1                module level
// 2                proc level
// 3                nested statements
// ...
//

type
  TSymTab = record
    tos: Natural; // top of stack
    stack: array of TStrTable;
  end;

procedure InitSymTab(out tab: TSymTab);
procedure DeinitSymTab(var tab: TSymTab);

function SymTabGet(const tab: TSymTab; s: PIdent): PSym;
function SymTabLocalGet(const tab: TSymTab; s: PIdent): PSym;

procedure SymTabAdd(var tab: TSymTab; e: PSym);
procedure SymTabAddAt(var tab: TSymTab; e: PSym; at: Natural);

function SymTabAddUnique(var tab: TSymTab; e: PSym): TResult;
function SymTabAddUniqueAt(var tab: TSymTab; e: PSym; at: Natural): TResult;
procedure OpenScope(var tab: TSymTab);
procedure RawCloseScope(var tab: TSymTab); // the real "closeScope" adds some
// checks in parsobj


// these are for debugging only:
procedure debug(n: PSym); overload;
procedure debug(n: PType); overload;
procedure debug(n: PNode); overload;

// --------------------------- ident tables ----------------------------------

function IdTableGet(const t: TIdTable; key: PIdObj): PObject;
procedure IdTablePut(var t: TIdTable; key: PIdObj; val: PObject);

function IdNodeTableGet(const t: TIdNodeTable; key: PIdObj): PNode;
procedure IdNodeTablePut(var t: TIdNodeTable; key: PIdObj; val: PNode);

procedure writeIdNodeTable(const t: TIdNodeTable);

// ------------- efficient integer sets -------------------------------------
const
  IntsPerTrunk = 8;
  InitIntSetSize = 8; // must be a power of two!
  BitsPerTrunk = IntsPerTrunk * sizeof(int) * 8;
  BitsPerInt = sizeof(int) * 8;

type
  PTrunk = ^TTrunk;
  TTrunk = record
    next: PTrunk; // all nodes are connected with this pointer
    key: int;    // start address at bit 0
    bits: array [0..IntsPerTrunk-1] of int; // a bit vector
  end;
  TTrunkSeq = array of PTrunk;
  TIntSet = record
    counter, max: int;
    head: PTrunk;
    data: TTrunkSeq;
  end;

function IntSetContains(const s: TIntSet; key: int): bool;
procedure IntSetIncl(var s: TIntSet; key: int);
procedure IntSetInit(var s: TIntSet);

function IntSetContainsOrIncl(var s: TIntSet; key: int): bool;

// ---------------------------------------------------------------------------
function getSymFromList(list: PNode; ident: PIdent; start: int = 0): PSym;
function lookupInRecord(n: PNode; field: PIdent): PSym;

function getModule(s: PSym): PSym;

function mustRehash(len, counter: int): bool;
function nextTry(h, maxHash: THash): THash;

implementation

function lookupInRecord(n: PNode; field: PIdent): PSym;
// XXX: transform in a node that contains the runtime check for the
// field, if it is in a case-part...
var
  i: int;
begin
  result := nil;
  case n.kind of
    nkRecList: begin
      for i := 0 to sonsLen(n)-1 do begin
        result := lookupInRecord(n.sons[i], field);
        if result <> nil then exit
      end
    end;
    nkRecCase: begin
      assert(n.sons[0].kind = nkSym);
      result := lookupInRecord(n.sons[0], field);
      if result <> nil then exit;
      for i := 1 to sonsLen(n)-1 do begin
        case n.sons[i].kind of
          nkOfBranch, nkElse: begin
            result := lookupInRecord(lastSon(n.sons[i]), field);
            if result <> nil then exit;
          end;
          else internalError('lookupInRecord(record case branch)');
        end
      end
    end;
    nkSym: begin
      if n.sym.name.id = field.id then result := n.sym;
    end;
    else internalError(n.info, 'lookupInRecord()');
  end;
end;

function getModule(s: PSym): PSym;
begin
  result := s;
  assert((result.kind = skModule) or (result.owner <> result));
  while (result <> nil) and (result.kind <> skModule) do result := result.owner;
end;

function getSymFromList(list: PNode; ident: PIdent; start: int = 0): PSym;
var
  i: int;
begin
  for i := start to sonsLen(list)-1 do begin
    assert(list.sons[i].kind = nkSym);
    result := list.sons[i].sym;
    if result.name.id = ident.id then exit
  end;
  result := nil
end;

// ---------------------- helpers --------------------------------------------

function hashNode(p: PObject): THash;
begin
  result := hashPtr({@cast}pointer(p))
end;

function mustRehash(len, counter: int): bool;
begin
  assert(len > counter);
  result := (len * 2 < counter * 3) or (len-counter < 4);
end;

// ---------------------------------------------------------------------------

// convert a node to a string; this is used for YAML code generation and
// debugging:

function spaces(x: int): PRope; // returns x spaces
begin
  result := toRope(repeatChar(x))
end;

function toYamlChar(c: Char): string;
begin
  case c of
    #0..#31, #128..#255: result := '\u' + strutils.toHex(ord(c), 4);
    '''', '"', '\': result := '\' + c;
    else result := c + ''
  end;
end;

function makeYamlString(const s: string): PRope;
// We have to split long strings into many ropes. Otherwise
// this could trigger InternalError(111). See the ropes module for
// further information.
const
  MaxLineLength = 64;
var
  i: int;
  res: string;
begin
  result := nil;
  res := '"' + '';
  for i := strStart to length(s)+strStart-1 do begin
    if i mod MaxLineLength = 0 then begin
      res := res +{&} '"' +{&} nl;
      app(result, toRope(res));
      res := '"'+''; // reset
    end;
    res := res +{&} toYamlChar(s[i]);
  end;
  res := res + '"';
  app(result, toRope(res));
end;

function symFlagsToStr(flags: TSymFlags): PRope;
var
  x: TSymFlag;
begin
  if flags = [] then
    result := toRope('[]')
  else begin
    result := nil;
    for x := low(TSymFlag) to high(TSymFlag) do
      if x in flags then begin
        if result <> nil then app(result, ', ');
        app(result, makeYamlString(symFlagToStr[x]));
      end;
    result := con('['+'', con(result, ']'+''))
  end
end;

function optionsToStr(flags: TOptions): PRope;
var
  x: TOption;
begin
  if flags = [] then
    result := toRope('[]')
  else begin
    result := nil;
    for x := low(TOption) to high(TOption) do
      if x in flags then begin
        if result <> nil then app(result, ', ');
        app(result, makeYamlString(optionToStr[x]));
      end;
    result := con('['+'', con(result, ']'+''))
  end
end;

function typeFlagsToStr(flags: TTypeFlags): PRope;
var
  x: TTypeFlag;
begin
  if flags = [] then
    result := toRope('[]')
  else begin
    result := nil;
    for x := low(TTypeFlag) to high(TTypeFlag) do
      if x in flags then begin
        if result <> nil then app(result, ', ');
        app(result, makeYamlString(typeFlagToStr[x]));
      end;
    result := con('['+'', con(result, ']'+''))
  end
end;

function lineInfoToStr(const info: TLineInfo): PRope;
begin
  result := ropeFormat('[$1, $2, $3]', [makeYamlString(toFilename(info)),
              toRope(toLinenumber(info)), toRope(toColumn(info))]);
end;

function treeToYamlAux(n: PNode; var marker: TObjectSet;
                       indent: int; maxRecDepth: int): PRope;
forward;

function symToYamlAux(n: PSym; var marker: TObjectSet;
                      indent: int; maxRecDepth: int): PRope; forward;
function typeToYamlAux(n: PType; var marker: TObjectSet;
                      indent: int; maxRecDepth: int): PRope; forward;

function strTableToYaml(const n: TStrTable; var marker: TObjectSet;
                        indent: int; maxRecDepth: int): PRope;
var
  istr: PRope;
  mycount, i: int;
begin
  istr := spaces(indent+2);
  result := toRope('['+'');
  mycount := 0;
  for i := 0 to high(n.data) do
    if n.data[i] <> nil then begin
      if mycount > 0 then app(result, ','+'');
      appRopeFormat(result, '$n$1$2',
        [istr, symToYamlAux(n.data[i], marker, indent+2, maxRecDepth-1)]);
      inc(mycount)
    end;
  if mycount > 0 then appRopeFormat(result, '$n$1', [spaces(indent)]);
  app(result, ']'+'');
  assert(mycount = n.counter);
end;

function ropeConstr(indent: int; const c: array of PRope): PRope;
// array of (name, value) pairs
var
  istr: PRope;
  i: int;
begin
  istr := spaces(indent+2);
  result := toRope('{'+'');
  i := 0;
  while i <= high(c) do begin
    if i > 0 then app(result, ','+'');
    appRopeFormat(result, '$n$1"$2": $3', [istr, c[i], c[i+1]]);
    inc(i, 2)
  end;
  appRopeFormat(result, '$n$1}', [spaces(indent)]);
end;

function symToYamlAux(n: PSym; var marker: TObjectSet;
                      indent: int; maxRecDepth: int): PRope;
var
  ast: PRope;
begin
  if n = nil then
    result := toRope('null')
  else if ObjectSetContainsOrIncl(marker, n) then
    result := ropeFormat('"$1 @$2"', [
      toRope(n.name.s),
      toRope(strutils.toHex({@cast}TAddress(n), sizeof(n)*2))])
  else begin
    ast := treeToYamlAux(n.ast, marker, indent+2, maxRecDepth-1);
    result := ropeConstr(indent, [
      toRope('kind'), makeYamlString(symKindToStr[n.kind]),
      toRope('name'), makeYamlString(n.name.s),
      toRope('typ'), typeToYamlAux(n.typ, marker, indent+2, maxRecDepth-1),
      toRope('info'), lineInfoToStr(n.info),
      toRope('flags'), symFlagsToStr(n.flags),
      toRope('magic'), makeYamlString(MagicToStr[n.magic]),
      toRope('ast'), ast,
      toRope('options'), optionsToStr(n.options),
      toRope('position'), toRope(n.position)
    ]);
  end
  // YYY: backend info?
end;

function typeToYamlAux(n: PType; var marker: TObjectSet;
                       indent: int; maxRecDepth: int): PRope;
begin
  if n = nil then
    result := toRope('null')
  else if objectSetContainsOrIncl(marker, n) then
    result := ropeFormat('"$1 @$2"', [
      toRope(typeKindToStr[n.kind]),
      toRope(strutils.toHex({@cast}TAddress(n), sizeof(n)*2))])
  else begin
    result := ropeConstr(indent, [
      toRope('kind'), makeYamlString(typeKindToStr[n.kind]),
      toRope('sym'), symToYamlAux(n.sym, marker, indent+2, maxRecDepth-1),
      toRope('n'+''), treeToYamlAux(n.n, marker, indent+2, maxRecDepth-1),
      toRope('flags'), typeFlagsToStr(n.flags),
      toRope('callconv'), makeYamlString(CallingConvToStr[n.callConv]),
      toRope('size'), toRope(n.size),
      toRope('align'), toRope(n.align)
    ]);
  end
end;

function treeToYamlAux(n: PNode; var marker: TObjectSet; indent: int;
                       maxRecDepth: int): PRope;
var
  istr: PRope;
  i: int;
begin
  if n = nil then
    result := toRope('null')
  else begin
    istr := spaces(indent+2);
    result := ropeFormat('{$n$1"kind": $2',
                         [istr, makeYamlString(nodeKindToStr[n.kind])]);
    if maxRecDepth <> 0 then begin
      appRopeFormat(result, ',$n$1"typ": $2',
        [istr, typeToYamlAux(n.typ, marker, indent+2, maxRecDepth)]);
      appRopeFormat(result, ',$n$1"info": $2',
        [istr, lineInfoToStr(n.info)]);
      case n.kind of
        nkCharLit..nkInt64Lit:
          appRopeFormat(result, '$n$1"intVal": $2', [istr, toRope(n.intVal)]);
        nkFloatLit, nkFloat32Lit, nkFloat64Lit:
          appRopeFormat(result, '$n$1"floatVal": $2',
                        [istr, toRopeF(n.floatVal)]);
        nkStrLit..nkTripleStrLit:
          appRopeFormat(result, '$n$1"strVal": $2',
                        [istr, makeYamlString(n.strVal)]);
        nkSym:
          appRopeFormat(result, ',$n$1"sym": $2',
            [istr, symToYamlAux(n.sym, marker, indent+2, maxRecDepth)]);

        nkIdent: begin
          if n.ident <> nil then
            appRopeFormat(result, '$n$1"ident": $2',
                          [istr, makeYamlString(n.ident.s)])
          else
            appRopeFormat(result, '$n$1"ident": null', [istr])
        end
        else begin
          if sonsLen(n) > 0 then begin
            appRopeFormat(result, ',$n$1"sons": [', [istr]);
            for i := 0 to sonsLen(n)-1 do begin
              if i > 0 then app(result, ','+'');
              appRopeFormat(result, '$n$1$2',
                [spaces(indent+4),
                 treeToYamlAux(n.sons[i], marker, indent + 4, maxRecDepth-1)]);
            end;
            appRopeFormat(result, '$n$1]', [istr]);
          end
        end
      end
    end;
    appRopeFormat(result, '$n$1}', [spaces(indent)]);
  end
end;

function treeToYaml(n: PNode; indent: int = 0; maxRecDepth: int = -1): PRope;
var
  marker: TObjectSet;
begin
  initObjectSet(marker);
  result := treeToYamlAux(n, marker, indent, maxRecDepth)
end;

function typeToYaml(n: PType; indent: int = 0; maxRecDepth: int = -1): PRope;
var
  marker: TObjectSet;
begin
  initObjectSet(marker);
  result := typeToYamlAux(n, marker, indent, maxRecDepth)
end;

function symToYaml(n: PSym; indent: int = 0; maxRecDepth: int = -1): PRope;
var
  marker: TObjectSet;
begin
  initObjectSet(marker);
  result := symToYamlAux(n, marker, indent, maxRecDepth)
end;

// these are for debugging only:
procedure debug(n: PSym); overload;
begin
  writeln(output, ropeToStr(symToYaml(n, 0, 3)));
end;

procedure debug(n: PType); overload;
begin
  writeln(output, ropeToStr(typeToYaml(n, 0, 3)));
end;

procedure debug(n: PNode); overload;
begin
  writeln(output, ropeToStr(treeToYaml(n, 0, -1)));
end;

// -------------------- node sets --------------------------------------------

{@ignore}
const
  EmptySeq = nil;
{@emit
const
  EmptySeq = [];
}

function nextTry(h, maxHash: THash): THash;
begin
  result := ((5*h) + 1) and maxHash;
  // For any initial h in range(maxHash), repeating that maxHash times
  // generates each int in range(maxHash) exactly once (see any text on
  // random-number generation for proof).
end;

function objectSetContains(const t: TObjectSet; obj: PObject): Boolean;
// returns true whether n is in t
var
  h: THash;
begin
  h := hashNode(obj) and high(t.data); // start with real hash value
  while t.data[h] <> nil do begin
    if (t.data[h] = obj) then begin
      result := true; exit
    end;
    h := nextTry(h, high(t.data))
  end;
  result := false
end;

procedure objectSetRawInsert(var data: TObjectSeq; obj: PObject);
var
  h: THash;
begin
  h := HashNode(obj) and high(data);
  while data[h] <> nil do begin
    assert(data[h] <> obj);
    h := nextTry(h, high(data))
  end;
  assert(data[h] = nil);
  data[h] := obj;
end;

procedure objectSetEnlarge(var t: TObjectSet);
var
  n: TObjectSeq;
  i: int;
begin
  n := emptySeq;
  setLength(n, length(t.data) * growthFactor);
{@ignore}
  fillChar(n[0], length(n)*sizeof(n[0]), 0);
{@emit}
  for i := 0 to high(t.data) do
    if t.data[i] <> nil then objectSetRawInsert(n, t.data[i]);
{@ignore}
  t.data := n;
{@emit
  swap(t.data, n);
}
end;

procedure objectSetIncl(var t: TObjectSet; obj: PObject);
begin
  if mustRehash(length(t.data), t.counter) then objectSetEnlarge(t);
  objectSetRawInsert(t.data, obj);
  inc(t.counter);
end;

function objectSetContainsOrIncl(var t: TObjectSet; obj: PObject): Boolean;
// returns true if obj is already in the string table:
var
  h: THash;
  it: PObject;
begin
  h := HashNode(obj) and high(t.data);
  repeat
    it := t.data[h];
    if it = nil then break;
    if it = obj then begin
      result := true; exit // found it
    end;
    h := nextTry(h, high(t.data))
  until false;
  if mustRehash(length(t.data), t.counter) then begin
    objectSetEnlarge(t);
    objectSetRawInsert(t.data, obj);
  end
  else begin
    assert(t.data[h] = nil);
    t.data[h] := obj;
  end;
  inc(t.counter);
  result := false
end;

// --------------------------- node tables -----------------------------------

function TableRawGet(const t: TTable; key: PObject): int;
var
  h: THash;
begin
  h := hashNode(key) and high(t.data); // start with real hash value
  while t.data[h].key <> nil do begin
    if (t.data[h].key = key) then begin
      result := h; exit
    end;
    h := nextTry(h, high(t.data))
  end;
  result := -1
end;

function TableSearch(const t: TTable; key, closure: PObject;
                     comparator: TCmpProc): PObject;
var
  h: THash;
begin
  h := hashNode(key) and high(t.data); // start with real hash value
  while t.data[h].key <> nil do begin
    if (t.data[h].key = key) then
      if comparator(t.data[h].val, closure) then begin // BUGFIX 1
        result := t.data[h].val; exit
      end;
    h := nextTry(h, high(t.data))
  end;
  result := nil
end;

function TableGet(const t: TTable; key: PObject): PObject;
var
  index: int;
begin
  index := TableRawGet(t, key);
  if index >= 0 then result := t.data[index].val
  else result := nil
end;

procedure TableRawInsert(var data: TPairSeq; key, val: PObject);
var
  h: THash;
begin
  h := HashNode(key) and high(data);
  while data[h].key <> nil do begin
    assert(data[h].key <> key);
    h := nextTry(h, high(data))
  end;
  assert(data[h].key = nil);
  data[h].key := key;
  data[h].val := val;
end;

procedure TableEnlarge(var t: TTable);
var
  n: TPairSeq;
  i: int;
begin
  n := emptySeq;
  setLength(n, length(t.data) * growthFactor);
{@ignore}
  fillChar(n[0], length(n)*sizeof(n[0]), 0);
{@emit}
  for i := 0 to high(t.data) do
    if t.data[i].key <> nil then
      TableRawInsert(n, t.data[i].key, t.data[i].val);
{@ignore}
  t.data := n;
{@emit
  swap(t.data, n);
}
end;

procedure TablePut(var t: TTable; key, val: PObject);
var
  index: int;
begin
  index := TableRawGet(t, key);
  if index >= 0 then
    t.data[index].val := val
  else begin
    if mustRehash(length(t.data), t.counter) then TableEnlarge(t);
    TableRawInsert(t.data, key, val);
    inc(t.counter)
  end;
end;

// ----------------------- string tables ------------------------------------

function StrTableContains(const t: TStrTable; n: PSym): Boolean;
var
  h: THash;
begin
  h := n.name.h and high(t.data); // start with real hash value
  while t.data[h] <> nil do begin
    if (t.data[h] = n) then begin
      result := true; exit
    end;
    h := nextTry(h, high(t.data))
  end;
  result := false
end;

procedure StrTableRawInsert(var data: TSymSeq; n: PSym);
var
  h: THash;
begin
  h := n.name.h and high(data);
  while data[h] <> nil do begin
    assert(data[h] <> n);
    h := nextTry(h, high(data))
  end;
  assert(data[h] = nil);
  data[h] := n;
end;

procedure StrTableEnlarge(var t: TStrTable);
var
  n: TSymSeq;
  i: int;
begin
  n := emptySeq;
  setLength(n, length(t.data) * growthFactor);
{@ignore}
  fillChar(n[0], length(n)*sizeof(n[0]), 0);
{@emit}
  for i := 0 to high(t.data) do
    if t.data[i] <> nil then StrTableRawInsert(n, t.data[i]);
{@ignore}
  t.data := n;
{@emit
  swap(t.data, n);
}
end;

procedure StrTableAdd(var t: TStrTable; n: PSym);
begin
  if mustRehash(length(t.data), t.counter) then StrTableEnlarge(t);
  StrTableRawInsert(t.data, n);
  inc(t.counter);
end;

function StrTableIncl(var t: TStrTable; n: PSym): Boolean;
// returns true if n is already in the string table:
var
  h: THash;
  it: PSym;
begin
  h := n.name.h and high(t.data);
  repeat
    it := t.data[h];
    if it = nil then break;
    if it.name.id = n.name.id then begin
      result := true; exit // found it
    end;
    h := nextTry(h, high(t.data))
  until false;
  if mustRehash(length(t.data), t.counter) then begin
    StrTableEnlarge(t);
    StrTableRawInsert(t.data, n);
  end
  else begin
    assert(t.data[h] = nil);
    t.data[h] := n;
  end;
  inc(t.counter);
  result := false
end;

function StrTableGet(const t: TStrTable; name: PIdent): PSym;
var
  h: THash;
begin
  h := name.h and high(t.data);
  repeat
    result := t.data[h];
    if result = nil then break;
    if result.name.id = name.id then
      break;
    h := nextTry(h, high(t.data))
  until false;
end;

// iterators:

function InitIdentIter(out ti: TIdentIter; const tab: TStrTable;
                       s: PIdent): PSym;
begin
  ti.h := s.h;
  ti.name := s;
  if tab.Counter = 0 then result := nil
  else result := NextIdentIter(ti, tab)
end;

function NextIdentIter(var ti: TIdentIter; const tab: TStrTable): PSym;
var
  h, start: THash;
begin
  h := ti.h and high(tab.data);
  start := h;
  result := tab.data[h];
  while (result <> nil) do begin
    if result.Name.id = ti.name.id then break;
    h := nextTry(h, high(tab.data));
    if h = start then begin
      result := nil;
      break
    end;
    result := tab.data[h]
  end;
  ti.h := nextTry(h, high(tab.data))
end;

function InitTabIter(out ti: TTabIter; const tab: TStrTable): PSym;
begin
  ti.h := 0; // we start by zero ...
  if tab.counter = 0 then result := nil // FIX 1: removed endless loop
  else result := NextIter(ti, tab)
end;

function NextIter(var ti: TTabIter; const tab: TStrTable): PSym;
begin
  result := nil;
  while (ti.h <= high(tab.data)) do begin
    result := tab.data[ti.h];
    Inc(ti.h); // ... and increment by one always
    if result <> nil then break
  end;
end;

// ------------------- symbol table ------------------------------------------

procedure InitSymTab(out tab: TSymTab);
begin
  tab.tos := 0;
  tab.stack := EmptySeq;
end;

procedure DeinitSymTab(var tab: TSymTab);
begin
  tab.stack := nil;
end;

function SymTabLocalGet(const tab: TSymTab; s: PIdent): PSym;
begin
  result := StrTableGet(tab.stack[tab.tos-1], s)
end;

function SymTabGet(const tab: TSymTab; s: PIdent): PSym;
var
  i: int;
begin
  for i := tab.tos-1 downto 0 do begin
    result := StrTableGet(tab.stack[i], s);
    if result <> nil then exit
  end;
  result := nil
end;

procedure SymTabAddAt(var tab: TSymTab; e: PSym; at: Natural);
begin
  StrTableAdd(tab.stack[at], e);
end;

procedure SymTabAdd(var tab: TSymTab; e: PSym);
begin
  StrTableAdd(tab.stack[tab.tos-1], e)
end;

function SymTabAddUniqueAt(var tab: TSymTab; e: PSym; at: Natural): TResult;
begin
  if StrTableGet(tab.stack[at], e.name) <> nil then begin
    result := Failure;
  end
  else begin
    StrTableAdd(tab.stack[at], e);
    result := Success
  end
end;

function SymTabAddUnique(var tab: TSymTab; e: PSym): TResult;
begin
  result := SymTabAddUniqueAt(tab, e, tab.tos-1)
end;

procedure OpenScope(var tab: TSymTab);
begin
  if tab.tos >= length(tab.stack) then
    SetLength(tab.stack, tab.tos + 1);
  initStrTable(tab.stack[tab.tos]);
  Inc(tab.tos)
end;

procedure RawCloseScope(var tab: TSymTab);
begin
  Dec(tab.tos);
  //tab.stack[tab.tos] := nil;
end;

// --------------------------- ident tables ----------------------------------

function hasEmptySlot(const data: TIdPairSeq): bool;
var
  h: THash;
begin
  for h := 0 to high(data) do
    if data[h].key = nil then begin result := true; exit end;
  result := false
end;

function IdTableRawGet(const t: TIdTable; key: PIdObj): int;
var
  h: THash;
begin
  h := key.id and high(t.data); // start with real hash value
  while t.data[h].key <> nil do begin
    if (t.data[h].key.id = key.id) then begin
      result := h; exit
    end;
    h := nextTry(h, high(t.data))
  end;
  result := -1
end;

function IdTableGet(const t: TIdTable; key: PIdObj): PObject;
var
  index: int;
begin
  index := IdTableRawGet(t, key);
  if index >= 0 then result := t.data[index].val
  else result := nil
end;

procedure IdTableRawInsert(var data: TIdPairSeq;
                           key: PIdObj; val: PObject);
var
  h: THash;
begin
  h := key.id and high(data);
  while data[h].key <> nil do begin
    assert(data[h].key.id <> key.id);
    h := nextTry(h, high(data))
  end;
  assert(data[h].key = nil);
  data[h].key := key;
  data[h].val := val;
end;

procedure IdTablePut(var t: TIdTable; key: PIdObj; val: PObject);
var
  index, i: int;
  n: TIdPairSeq;
begin
  index := IdTableRawGet(t, key);
  if index >= 0 then begin
    assert(t.data[index].key <> nil);
    t.data[index].val := val
  end
  else begin
    if mustRehash(length(t.data), t.counter) then begin
      setLength(n, length(t.data) * growthFactor);
    {@ignore}
      fillChar(n[0], length(n)*sizeof(n[0]), 0);
    {@emit}
      for i := 0 to high(t.data) do
        if t.data[i].key <> nil then
          IdTableRawInsert(n, t.data[i].key, t.data[i].val);
      assert(hasEmptySlot(n));
    {@ignore}
      t.data := n;
    {@emit
      swap(t.data, n);
    }
    end;
    IdTableRawInsert(t.data, key, val);
    inc(t.counter)
  end;
end;


procedure writeIdNodeTable(const t: TIdNodeTable);
var
  h: THash;
begin
{@ignore}
  write('{'+'');
  for h := 0 to high(t.data) do
    if t.data[h].key <> nil then begin
      write(t.data[h].key.id : 5);
    end;
  writeln('}'+'');
{@emit}
end;

function IdNodeTableRawGet(const t: TIdNodeTable; key: PIdObj): int;
var
  h: THash;
begin
  h := key.id and high(t.data); // start with real hash value
  while t.data[h].key <> nil do begin
    if (t.data[h].key.id = key.id) then begin
      result := h; exit
    end;
    h := nextTry(h, high(t.data))
  end;
  result := -1
end;

function IdNodeTableGet(const t: TIdNodeTable; key: PIdObj): PNode;
var
  index: int;
begin
  index := IdNodeTableRawGet(t, key);
  if index >= 0 then result := t.data[index].val
  else result := nil
end;

procedure IdNodeTableRawInsert(var data: TIdNodePairSeq;
                               key: PIdObj; val: PNode);
var
  h: THash;
begin
  h := key.id and high(data);
  while data[h].key <> nil do begin
    assert(data[h].key.id <> key.id);
    h := nextTry(h, high(data))
  end;
  assert(data[h].key = nil);
  data[h].key := key;
  data[h].val := val;
end;

procedure IdNodeTablePut(var t: TIdNodeTable; key: PIdObj; val: PNode);
var
  index, i: int;
  n: TIdNodePairSeq;
begin
  index := IdNodeTableRawGet(t, key);
  if index >= 0 then begin
    assert(t.data[index].key <> nil);
    t.data[index].val := val
  end
  else begin
    if mustRehash(length(t.data), t.counter) then begin
      setLength(n, length(t.data) * growthFactor);
    {@ignore}
      fillChar(n[0], length(n)*sizeof(n[0]), 0);
    {@emit}
      for i := 0 to high(t.data) do
        if t.data[i].key <> nil then
          IdNodeTableRawInsert(n, t.data[i].key, t.data[i].val);
    {@ignore}
      t.data := n;
    {@emit
      swap(t.data, n);
    }
    end;
    IdNodeTableRawInsert(t.data, key, val);
    inc(t.counter)
  end;
end;

// ---------------- efficient integer sets ----------------------------------
// Same algorithm as the one the GC uses

procedure IntSetInit(var s: TIntSet);
begin
{@ignore}
  fillChar(s, sizeof(s), 0);
{@emit
  s.data := []; }
  setLength(s.data, InitIntSetSize);
{@ignore}
  fillChar(s.data[0], length(s.data)*sizeof(s.data[0]), 0);
{@emit}
  s.max := InitIntSetSize-1;
  s.counter := 0;
  s.head := nil
end;

function IntSetGet(const t: TIntSet; key: int): PTrunk;
var
  h: int;
begin
  h := key and t.max;
  while t.data[h] <> nil do begin
    if t.data[h].key = key then begin
      result := t.data[h]; exit
    end;
    h := nextTry(h, t.max)
  end;
  result := nil
end;

procedure IntSetRawInsert(const t: TIntSet; var data: TTrunkSeq;
                          desc: PTrunk);
var
  h: int;
begin
  h := desc.key and t.max;
  while data[h] <> nil do begin
    assert(data[h] <> desc);
    h := nextTry(h, t.max)
  end;
  assert(data[h] = nil);
  data[h] := desc
end;

procedure IntSetEnlarge(var t: TIntSet);
var
  n: TTrunkSeq;
  i, oldMax: int;
begin
  oldMax := t.max;
  t.max := ((t.max+1)*2)-1;
  {@emit n := []}
  setLength(n, t.max + 1);
{@ignore}
  fillChar(n[0], length(n)*sizeof(n[0]), 0);
{@emit}
  for i := 0 to oldmax do
    if t.data[i] <> nil then
      IntSetRawInsert(t, n, t.data[i]);
{@ignore}
  t.data := n;
{@emit
  swap(t.data, n);
}
end;

function IntSetPut(var t: TIntSet; key: int): PTrunk;
var
  h: int;
begin
  h := key and t.max;
  while t.data[h] <> nil do begin
    if t.data[h].key = key then begin
      result := t.data[h]; exit
    end;
    h := nextTry(h, t.max)
  end;

  if mustRehash(t.max+1, t.counter) then IntSetEnlarge(t);
  inc(t.counter);
  h := key and t.max;
  while t.data[h] <> nil do h := nextTry(h, t.max);
  assert(t.data[h] = nil);
  new(result);
{@ignore}
  fillChar(result^, sizeof(result^), 0);
{@emit}
  result.next := t.head;
  result.key := key;
  t.head := result;
  t.data[h] := result;
end;

// ---------- slightly higher level procs ----------------------------------

function transform(key: int): int;
begin
  if key < 0 then result := 1000000000 + key // avoid negative numbers!
  else result := key
end;

function IntSetContains(const s: TIntSet; key: int): bool;
var
  u: int;
  t: PTrunk;
begin
  u := transform(key);
  t := IntSetGet(s, u div BitsPerTrunk);
  if t <> nil then begin
    u := u mod BitsPerTrunk;
    result := (t.bits[u div BitsPerInt]
      and (1 shl (u mod BitsPerInt))) <> 0
  end
  else
    result := false
end;

procedure IntSetIncl(var s: TIntSet; key: int);
var
  u: int;
  t: PTrunk;
begin
  u := transform(key);
  t := IntSetPut(s, u div BitsPerTrunk);
  u := u mod BitsPerTrunk;
  t.bits[u div BitsPerInt] := t.bits[u div BitsPerInt]
                            or (1 shl (u mod BitsPerInt));
end;

function IntSetContainsOrIncl(var s: TIntSet; key: int): bool;
var
  u: int;
  t: PTrunk;
begin
  u := transform(key);
  t := IntSetGet(s, u div BitsPerTrunk);
  if t <> nil then begin
    u := u mod BitsPerTrunk;
    result := (t.bits[u div BitsPerInt]
          and (1 shl (u mod BitsPerInt))) <> 0;
    if not result then
      t.bits[u div BitsPerInt] := t.bits[u div BitsPerInt]
                                or (1 shl (u mod BitsPerInt));
  end
  else begin
    IntSetIncl(s, key);
    result := false
  end
end;

end.