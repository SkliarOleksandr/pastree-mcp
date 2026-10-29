# pastree-mcp - design

What the server is for, how its tools are shaped and why, and what is still
open. README.md says how to run it; this file says why it is the way it is.
Do not re-derive these decisions without reading the reason first.

## 1. The problem it solves

An agent working in a large Delphi code base spends most of its tokens on
*finding* things: grep for a name, read the hits, open files to tell the one
real `Bar` from forty unrelated ones, read a 6,000-line unit to learn its
structure. None of that is reasoning about the code; it is reconstructing
what a semantic analyzer already knows.

PasTree knows it. pastree-lsp already puts that knowledge behind LSP for
editors. This server puts it behind MCP for agents, and shapes it for them.

## 2. Why a separate server and not the LSP server behind a bridge

A bridge was the first idea and was rejected, for four reasons:

1. **Addressing.** LSP asks "what is at line 120, column 17". An agent knows
   names (`TFoo.Bar`) and is unreliable at counting columns. Every tool here
   takes a name or file + line + the identifier as written.
2. **Answer shape.** LSP answers in JSON Location arrays with URIs; every
   byte of a tool result is paid for by the agent on every later turn. Here:
   paths relative to the group directory, rows grouped by file, one trimmed
   source line per row, a cap with "N more".
3. **Groups.** pastree-lsp is one project per process (its IDE plugin runs one
   server per member of a group). An agent's questions are group-wide.
4. **Lifecycle.** An editor pushes buffers; an agent edits files on disk and
   expects the next answer to see the edit. Here the server watches the disk
   (section 5).

Dependency: PasTree only (linked from source, `..\object-pascal-tree`). No
code is shared with pastree-lsp; where the two do the same thing (reading
the registry library paths, the IDE's default namespaces and aliases), the
PasTree demo and pastree-lsp are the reference and are cited in the code.

## 3. Tools

Common rules:

- **Target addressing** (definition, source, members, references, callers, callees, impact, related): `symbol` - a name,
  optionally qualified from the right (`Bar`, `TFoo.Bar`, `UnitName.TFoo.Bar`;
  generic parameters ignored) - or `file` + `line` + `name` (the identifier
  written on that line; `column` only when it occurs twice). An ambiguous name
  is an error that LISTS the candidates with file:line, so the next call can
  pick one; `kind` narrows (`class`, `function`, `property`...). A unit is
  its name - a dotted one too: `PasMcp.Log` names the unit before it is read
  as `PasMcp` + `Log` relaxed (which found the routines Log of that unit and
  left the unit unreachable by name, 0.24.1) - or `kind: unit` (wildcards
  too), or its `file` alone. The
  overloads of one routine are no ambiguity for `source`, `references`,
  `callers` and `impact`, which answer for each (0.22.0); a tool taking one
  routine (`callees`, `related`) refuses them with the advice that works,
  `file` + `line` - "qualify it" cannot tell overloads apart. On the client
  group an audit's agents were refused 30 times on overloads and went on with
  file + line in 23, with grep in 7.
- **A member through the type that inherits it**: `TDerived.Member`, as code
  writes it, when nothing declares the name with that qualifier - the
  qualifier resolved as a type, the member found as a call binds it
  (`FindMemberX` climbs the ancestors), and every overload of that
  declaration: `find` tags each row `[inherited by TDerived]`, the other
  tools answer for the ancestor's declaration, which their header names. It
  was "no declaration matches", taken for "no such member" (0.22.0).
  `TDerived.*Bar*` lists the ancestors' matches after the type's own, a
  name found lower down not again from above (0.37.0): the wildcard found
  nothing where the exact name found the member (a field report).
- **A name nothing declares** is answered with the names like it (0.37.0):
  `find` after the names containing it, every other tool in its refusal
  (the group's own units: a wildcard over the libraries would make them
  full in light mode, for a hint). Like it: Dice of the CamelCase words at
  0.6 or more (a type's T or I prefix not a word), or one edit away (two in
  a name of ten letters or more). An agent's guess, TaviCreditStatus, rarely
  contains the real TCreditStatus, and `*name*` missed it (a field report).
  Among names as many words alike, one ending in the query's last word
  comes first - a CamelCase name is its last word - and, for a query like
  a type's (T, I or E, then a capital within four letters: TFoo, TaviFoo),
  a type before a member (0.43.1). TaviCreditTransactionStatus put the type
  TCreditTransactionStatus sixth, after four CreditTransactionStatus
  properties and a class, and `source`'s refusal, which lists six, left it
  out (a field report).
- **Wildcards in any segment** (`*.Save`, `*Form.Save`, `TFoo*.Bar`): a
  qualifier is matched against the declaration's unit + owner chain as the
  last segment against its name. Only the last segment took them, and `*.X`
  answered "no declaration matches" where `X` found 16 - the same false
  "none" (0.22.0).
- **What a name can find**: declarations at unit level and struct members -
  PasTree's `ProjectOutline` filter (types, routines, variables, constants,
  fields, properties with a source declaration) - and enum values, by their
  name or as `TEnum.Value` (`kind: enum`); a scoped enum's value
  (`{$SCOPEDENUMS ON}`) by its bare name only when nothing else has it, as
  code cannot write it so - the RTL's scoped `Exception` value would make the
  class ambiguous. The filter leaves enum values out, and `find` said a value
  written on 29 lines of the client group existed nowhere (0.17.0). Locals
  and parameters are reachable by position only. A name matching no declaration but a unit name
  targets the unit.
- **Identity across a group**: a symbol's declaration site (file, line,
  column). A search runs in every analysis holding that site and the rows are
  merged and de-duplicated by hit site.
- **Order**: the group's own files first, then libraries; by file and line.
  An own unit a tool wrote - a type library import (`*_TLB`), a WSDL
  import, an XML data binding, told by its name and the header the tool
  writes - after the other own ones, and `find` says how many (0.38.0).
- **`find` narrows** (0.38.0): `in` takes the files whose path contains it
  or matches it as a wildcard, as `references` does; a list cut at `limit`
  (and `limit: 0`) counts the matches by unit, the own units first - where
  the rest are, to narrow by. A field report: `*Customer*` gave 71 rows, 17
  of them the ones wanted, the rest SOAP and TLB imports, with nothing to
  say where; `path` was taken for a filter and dropped without a word.
- **The cap and the count**: `limit` caps the rows; the header counts every
  row, cut or not, and the cut says how many it left out. `limit: 0` (0.19.0,
  every tool that lists rows: `find`, `references`, `callers`, `callees`,
  `impact`, `related`, `members`, `outline`, `form`) answers whether and how
  many with no rows at all - the header, the notes (what was not seen, the
  form lines among the uses, the implementation headers) and the "N more".
  Many agent questions are "is it used", "is there one", and the rows of a
  heavily used symbol are paid for anyway: on the client group
  `references` of TabOrder 2,683 tokens (150 of 6,355 rows) -> 83, of an
  enum type 3,595 -> 28, `find *Lab*` 758 -> 11. The work is the same - every
  row is found to be counted - except the walks by level: `callers`,
  `callees` and `impact` search a deeper level only for rows that are shown,
  so with 0 only the first level is counted, and the answer says so. The
  rows `find` does not list are counted by declaration node, an estimate
  when two analyses hold a unit (it was one off in 5,575).
- **Where a row sits**: `references`, `callers`, `impact`, `compile`, the statement relations of
  `related` (`assignments`, `creations`, `destructions`) and `diagnostics` name the
  innermost routine or type around each row - `TFoo.Save`, `TFoo.Save.Helper`
  in a nested routine, `TFoo` for a member declaration - so "who uses X" is
  answered without opening a file to see which method a line is in. A grouped
  answer prints the name once, as a heading over its run of rows. A row on
  the line that names its own declaration (a routine's header, `TFoo =
  class`) shows that name already and gets the next one out; a row in no
  routine or type (a `uses` clause) stays at the file level. `diagnostics`
  shows no source line, so each of its rows ends `(in TFoo.Save)`, header
  lines included. The declaration relations (`descendants`, `overrides`,
  `implementations`) get none: their `[tag]` names the type. A `callees`
  row is a declaration too, and sits under its type. The name comes
  from the public tree - the nearest `nkRoutine` or `nkTypeDecl` ancestor,
  the climb PasTree's private `RTEnclosingRoutine` makes - once per file per
  call.
- **Errors the agent can act on** (unknown name, ambiguity, file not in any
  closure, wrong relation for the symbol) are tool results with `isError`
  set, as MCP specifies - the agent reads those; a protocol error would only
  be logged.
- **Arguments are checked against the catalogue** (0.33.0): a name the tool
  does not take is refused with the ones it does, and the likely one
  (`filter` - `match`, `path` - `in`, a misspelling); a value outside an
  enum is refused with the values. Before, both were dropped without a word
  and the answer read as the filtered one: a field report counted "the
  filters of `members` and `find` are silently ignored" among what slowed an
  agent down (`find` with `path`, `members` with `filter`, `outline` with
  `line`). The schemas stay open (no `additionalProperties: false`): a
  client refusing first would not say which argument was meant.
- **`file` + `line` alone** (0.33.0) is the routine around that line - the
  innermost one, named on its header - for every tool addressed by
  position.
- **Freshness note**: when the call had to re-analyze changed files first,
  the answer starts with `(index: re-analyzed N changed file(s) in X ms: a.pas,
  b.pas)` - the files named, 8 of them and the rest counted, a unit shared by
  several analyses once; `; deleted: c.pas` for a file gone, `; added: d.pas`
  for a unit or include the re-analysis took in, `form file(s) changed:` /
  `added:` / `deleted:` for an own unit's `.dfm`/`.fmx` (re-read without any
  re-analysis - a designer's save changes no Pascal file), `(index: project
  file(s) changed: A.dproj; the workspace was reloaded)` for a `.dproj` or the
  group. An error answer carries it too - the re-analysis happened, and the
  next call does not report it again. A file the agent did not edit is
  someone else's edit, and the note is
  the only sign of it: a session on PasTree saw `re-analyzed 2 changed file(s)`
  when it had edited nothing, and learned an hour later, from a build failing
  on another session's half-written unit, whose they were.
- **Declaration rows** (`find`, `definition`, `members`, `callees`, an
  ambiguity's candidates) show the declaration's head, and one written over
  several lines is joined: `function ParseVarSection(AClassVar: Boolean;`
  alone reads as a routine of one parameter. A routine, property, variable,
  field or constant ends at the `;` after it, outside brackets; a type at the
  first line end with every bracket closed (a class's members follow its
  `class(TBase,` / `IFoo)`). The first and last lines are taken whole, as a
  one-line declaration is - `class function` before the name, directives
  after the `;` - and the text is the tokens the compiler reads, one space
  between two, so a comment, a directive or a branch not compiled is left
  out: joined into one line, a `//` would swallow the rest. Past 160
  characters it is cut after a `;` or `,` with ` ...`, the text from the last
  `)` on kept when short - `function Foo(A: X; B: Y; ...): Integer;` - since
  a cut anywhere else reads as another parameter. On the client group the
  bench's members and callees answers grew 1-12% (a record class with 30
  such methods: 2.9k -> 3.3k tokens).

| Tool | PasTree underneath | Notes |
| --- | --- | --- |
| `status` | project + model counts, `UsesList` health | Answers during loading too. First the server itself - its version, PasTree's, when the exe was built (read at start: `build.bat` puts the next build at the same path), the pid, when it started - and the log file it writes (0.23.0): on the day of the audit eleven servers of five versions were running, and which one answered a session took the process list and the renamed exe copies. A project outside the group given by `--also` is a member marked so. Lists unit names that do not resolve: each one silences its importers' diagnostics, so it is the thing to know before trusting "no errors" or "no references". |
| `find` | symbol tables of every model, filtered by `NamedDeclRoot` (the rule of `ProjectOutline` and `FindDeclarations`) | Exact, qualified or wildcard - in any segment, and a member through the type inheriting it (the common rules above). A routine nested in a body and a type declared there are named under the routine (`TFoo.Bar.Helper`, `ScopeOwner`); a copy of the old filter stopped at the first routine scope, so no nested routine was found and the answer said no file wrote it (0.44.0). No exact hit lists the locals, constants and parameters of the own units' bodies by that name, under their routine - the refusal of every `symbol` tool said a local is addressed by file + line + name and gave neither; with none, it falls back to `*query*` and says so. `in` also matches the include file a declaration is written in. Declaration sites are computed only for the rows shown - on the client group `Create` matches 25,000 symbols. `scope: project` = own units only. Nothing found says what was searched - `the 89 units indexed - what pastree-mcp.dproj compiles: 10 of its own, 79 from libraries` - and where the name is written outside the index: the index is the projects' `uses` closure, not the directory, and a unit no project uses is invisible to every tool. A session on PasTree, pointed at pastree-mcp's project, asked for its tree checker and its test kit and got a bare "no declaration matches", which cannot be told from "there is none". The Pascal sources no analysis holds - under the group directory at every level (`.git`, `__history`, `__recovery` skipped) and in the members' own search path directories, not the registry library path - are read as text, each segment of the name required in the file; per file the line that best says where it is, one that declares the dotted name or the last segment (a routine or `unit` keyword before it, or `=` / `:` after it) before one that only writes it, a declaration's parameter lines joined; a qualified name only scattered over a file leaves the file out. 5 files listed, the rest counted; 2 s at most, and the answer says when that cut the search short. The same note follows an exact miss's `*query*` rows, when it finds something, and every `symbol` a tool cannot resolve. On the client group 158 such files, 330 ms: an unused tool's `.dpr` found by its name. |
| `definition` | `DeclHit`, `GotoImplementation` | For a routine also the implementation (its header line, found by scanning up from the body start `GotoImplementation` returns). `context: N` appends N source lines - of the implementation when there is one. Several matches are all listed; this is the one tool where a list is the answer. |
| `source` | `DeclRootOf`, `GotoImplementation`, the raw token stream | The exact text of one declaration: a routine's implementation (`part: impl`, the default when it has one), its declaration (`decl`) or both; a type's whole declaration; a constant with its value. The node's span gives both ends - no line count to guess, as `definition context` makes the agent do. A name whose candidates are all overloads of one routine - one type's method, one unit's routine - shows each, headed by its declaration line, `limit` counted over them all and the ones past it named: refused, an agent read the file instead of making the second call (FR.3). Namesakes in different types are refused with the candidates, as elsewhere. The comment directly above comes with it, read from the comment tokens the lexer keeps: comments starting their own line, no blank line between them and the declaration; one longer than 30 lines is named, not shown (in old code it is as often a commented-out earlier version as documentation). Lines come from the model's token stream, so they are numbered like every other answer - a tab between the number and the line (0.36.0; `definition`'s context too), as Claude Code's own Read writes it: two spaces ran into the line's indentation, and an edit copied from the answer once missed the file (a field report). `limit` caps each part (300 lines). `lines` (`40-80`, `40-`, `-80`, `40`, file line numbers) cuts each part to those lines, said on the line after its heading, and a part outside them says so (0.23.0): a long routine was read with `sed` at the numbers a caller row or an error gave, since `source` could only give all of it - 3,167 tokens for a 293-line routine where the 15 lines wanted are 177. A range wholly above the part and no longer than it is counted from its first line instead, and said (0.35.0): `-40` read as "its first 40 lines" was answered "outside it" on a routine at 629-735 (a field report); a range outside it otherwise names the part's span. A routine with no body says why: abstract, an interface method, external. |
| `members` | `EnumMembersX`, `DeclTypeX`/`SymDeclTypeX`, `XParamSyms`, `IsBarePropertyRedecl` | Every member of a class, record or interface, the inherited ones included: an outline per ancestor - once the ancestors are found - in one call. Rows are grouped by the type declaring them, the type asked about first and then each ancestor as `FindMemberX` climbs, under the visibility section they are written in (`published` for the unnamed first section of a `TPersistent` descendant), one declaration line each; the header is the ancestry, `TDerived <- TBase <- TObject`. The first member of a name met is the one a call binds to, so a later one is what an override or a redeclaration replaces, and is left out - unless every routine of the name met so far says `overload` or `override` (an override replaces one slot: `TStrings.AddStrings(TArray<string>)` is still called on a `TStringList`) and its parameter types are its own. A bare `property Items;` says nothing of its type: `[type TStrings]`. Whose reach: by default the type's own methods - all of its own members, of an ancestor's what Delphi lets them reach (`private` only in the same unit, `strict private` never); for a library type, what any code can use, since no method of it is the agent's to write; a variable, field, property or parameter (an inline `var X := ...` included) lists the members of its type that code in its unit can use. `visibility` public, protected (a descendant in another unit) or all; what it leaves out is counted. A library ancestor of a group type is counted per type, not listed (`library: true` lists it), unless `match` looks for a name: a form's run to `TObject` is 640 members the agent knows. `member_kind` and `match` narrow - `kind` already narrows the target, and one parameter read two ways is one more thing the model gets wrong. `limit` (150) caps the rows; the rest is counted per type. No class helper: one is in effect where it is in scope, and a type asked about has no such place. |
| `references` | `FindReferences`, `FindUnitReferences`, `FindBuiltinReferences`, `FindDefineReferences` | The name of an overloaded routine lists every overload's uses in one answer, each row tagged `[overload at N]` by the declaration line of the one it binds to, and the header counts each (`1 at 25, 0 at 26`): "is this overload used" is the usual question (0.22.0). Rows in compiled units read from a `.dcu` (no source) are counted, not shown. `mode: files` (0.26.0) answers with a row per file and its count, under its directory, the code files first when `limit` (then a count of files) cuts; `in` lists the rows of the files whose path relative to the group contains it or matches it as a wildcard (`*.pas`, `client*Edit*`), the header still counting every row; `mode: count` is `limit: 0`. TabOrder on the client group: 85,884 tokens as lines, 6,753 as the map of its 867 files, its 303 code rows 6,422 (9.2). A default array property's uses written without its name, `X[I]`, are rows tagged `[X[I]]` and counted in a note: PasTree binds the brackets to the property (0.76.0), a rename leaves them as they are. They were missing and said missing before 0.21.0 - the search followed names. A routine no code names by name, reached through the virtual method it overrides, an interface method it implements or a property it is the accessor of, says so with the count `callers` finds - "0 references" alone was read as dead code (24 of 384 sampled symbols on the client group: 1 to 1,334 calls each). A published property's form lines - `Caption = ...` set on an object whose class has it, a bare `property X;` taken for the property it republishes - are rows under their component (PasTree 0.68.0): TReader sets it by name, so renaming or removing it fails when the form loads after a clean compile; one no form sets says "no form file sets it". A sub-property (`Font.Name`) is looked up in the class of the property before it, an item's property in the item class of its collection - the type of the collection's `default` array property, whatever its name (`TActionClients.ActionClients`), else `Items` (PasTree 0.70.0); a sibling `<Prop>ClassName` string line (`PropertiesClassName`, the DevExpress editors' convention) names the class read. Where the class read is a declared type without the property - a descendant item class, a property object whose class is chosen at run time (`CommandProperties.Font` of an action item: TTextProperties or TMenuProperties by its `CommandStyle`) - the line is a row tagged `[may be another class's]` and said once: left out, it is a silent miss (18 `CommandProperties.Font.Name` lines on the client group). An answer the limit cuts lists its code rows first and counts the form lines it left out - form lines filling the rows by file name hid the code a rename changes (25 `property TabOrder;` redeclarations behind 5,000 `TabOrder = N` lines). The name written in a conditional branch the analyzed configuration does not compile is not a row - nothing there is resolved - but the lines are named (the first five) and counted: an edit made from the rows misses them, and the build that selects the branch breaks; `definition` at such a line says the branch is not compiled. Counted only where the symbol could be named - the unit declaring it, a unit whose uses reach it (every unit reaches System), or one whose uncompiled text names that unit - and not in an include file from outside the group's tree (0.23.0): on the client group `Create` of one class counted 196 such lines and a property `Value` 75, namesakes in type library imports, vendored library sources and a library's `.inc`; over the 46 answers of the battery that had the note, 1,119 lines -> 360, times unchanged. |
| `callers` | `FindReferences` per source, `MethodAt`+`FindOverrides`, `FindDescendants`, `FindMemberX`, `BareInheritedTarget`, `XDescendsFrom`, `WithTargetTypeX` | `references` folded to the routines the calls sit in, and what a reference search cannot see. A call is written against a *source*: the routine; a virtual method it overrides (the chain climbed from its class, stopping at the root or a `reintroduce`); an interface method it implements - a same-named method of an interface that its class, an ancestor or a descendant lists, or that one extends, when the member that name finds from the listing class is the routine or a method it overrides (`FindImplementations` is not asked: it answers only for the interface a class lists itself); a property it is the getter (reads) or setter (writes) of. Through a virtual slot a row counts only when the receiver's static type may hold an object that runs this implementation (`LSquare.Area` bound to `TShape.Area` never runs `TCircle.Area`; a property read on a class that overrides the getter runs the override), and `inherited X` never dispatches. A bare `inherited;` names nothing: the overrides below the class - for a constructor that is not virtual, the same-named constructors of its descendants - are scanned for one, and `BareInheritedTarget` says what it calls. Each reference is classified from the tree: a call, or the routine handed on - `@Foo`, `OnClick := Foo`, a procedure passed as an argument - tagged `[not a call]` and not followed. A function named without parentheses is a call unless assigned to something procedural; as an argument it is taken for a call. `depth` 1-4 follows the routines the calls sit in, own files only (a library routine is shown, not followed), each site once; `limit` (150) caps the rows over all levels, and a level past it is not searched - the answer says so (a getter read 379 times, depth 3 and no cap: 34 s, 81k tokens). Tags: `via X` for a row bound to another source - dropped from the rows and said once above them when every first-level row shares it; `-> X` on a deeper row, the routine of the level above it reaches; overloads of one name told apart by declaration line. A routine searched and found uncalled is named at the end, and a published one (or in the unnamed first section of a `TPersistent` descendant) gets the note that a `.dfm` may bind it (9.5). A destructor points to `related destructions`. The name of an overloaded routine walks from every overload at once, each root named by its declaration line - `[-> TBase.Add (line 26)]` on a row - and the header counts each one's rows (0.22.0). |
| `callees` | the body's `RefMap`/`ExtRefMap`, `RefUse`, `PropertyRedeclPrev`, `BareInheritedTarget`, `FindMemberX` over a class index (`AncestorOfX`, `ListedInterfaces`) built once per call | What a routine calls - `callers` from the other end. The body is walked from the tree - its block, its local declarations and anonymous methods, not its nested routines, which are callees of their own - and each name is taken for what it binds to: the overload the compiler chose (PasTree writes it into the maps), a property's getter or setter for a read or a write (a republished `property X;` takes its ancestor's), what a bare `inherited;` runs; a routine handed on (`OnClick := Foo`, `@Foo`) is `[not a call]`, classified as in `callers`. One row per routine reached, at its declaration line, grouped by file under its type, with the lines of its calls: `[at 19, 31]`. A virtual call made on an object - not on a type name, not `inherited X` - adds what that object may run: for its static class and every class below, the method the slot finds there, its own or the nearest ancestor's - so an override between the method's class and the object's is found (a property's accessor binds where the property is declared), not only those below. An interface call: the same over every class taking the interface on, listing it or one extending it. `[via X]` names what the call is written against. More than 10 such methods, merged over the analyses, are counted, not listed: a base class's hook called on Self has a dozen or two in a real group. The search looks at 5000 classes below the method's class at most; below `TObject` a real group has more, and then the count is `at least N` and the rows, when listed, are said to be what it found (0.44.3: `TObject.Destroy` on the client group was counted 1440 in light mode and 1438 in full, of 5216). Calls through a method pointer or a procedural variable are named - what they run is assigned at run time - and built-ins listed once. `depth` 1-4 follows the routines reached, own files and with a body, each once; a row below the first level names its caller, `[TFoo.Load at 40]`; `limit` (150) caps the rows over all levels. `X[I]` over a default array property runs its getter, or its setter when the brackets are what is assigned (0.21.0). Not seen: a record's operators and implicit conversions, a for-in's enumerator, a method resolution clause (`procedure IFoo.Bar = Baz`). |
| `impact` | the walk of `callers` over several roots, `FindReferences`, `FindUnitReferences`, `FindImplementations`, each model's `UsesList`, the model `Diags` | What a change reaches, in one answer: `callers`, `related overrides` and `unit_deps` at once, and the question none of them answers - which members of the group to build and test. Given a unified diff (`git diff` output the agent passes as text - the server runs no git) or declarations (`symbol`, `symbols`, file + line + name). A diff's paths resolve against the group directory or a directory above it: git writes them from the repository root, which may hold more than the group. Its `+` and context lines must read as the file on disk does - compared with every character past ASCII dropped, since a diff that went through a console may carry those in another encoding - or the file is refused by name: a diff of another state numbers another file. A changed line of code touches the innermost declaration around its tokens: a routine as a whole (a nested routine, an anonymous method, a local are its routine's), a type, a variable, constant or property of a unit or a type; of those met on one line, one holding another is left out (the `;` after `property X ... read FX` is the class's token). A line with no token of its own (a directive) is the point between the tokens around it. A run of removed lines beside added code is read from the added lines alone - its removal point, between two members, would name the class - and a run that only removes is that point; out of a type, the members it removes are named rather than the type. Outside every declaration, the place: a uses clause, initialization, finalization, a main block, exports. Comment-only lines touch nothing (read from the diff's text, so removed lines too). A type every line of which is added is new: listed alone, its members and their implementations folded into it. A removed routine, property or type - declared on a removed line and on no added one, so a changed signature is not a removal - or a field removed from a type is named with the own-unit diagnostics still quoting its name: the calls a rename or a deletion left behind. **Members to build and test**: those whose closure holds a changed unit (a form's unit, an include's includers, a `.dproj`'s own member) - a member's closure is what its main source reaches through `uses`, read per member in its own analysis, since an analysis holds several (section 4); a file compiled into fewer members than the list is tagged with them. A unit whose interface section changed says how many units use it, their names up to 8 (the dependents' own recompile, and where to run `diagnostics`). Each declaration says the method it overrides (the chain's nearest link - what a changed signature must still match), the interface methods and properties it is also called through, its overrides and, for an interface method, its implementations - 10 each, then counted. Then the walk of `callers` from all of them at once: a declaration that is no routine is searched for its uses, a field also through the property that reads or writes it; with several roots a row names the one it reaches (`-> X`). 40 roots are searched (the walk is the time: about 125 ms a root on the client group), 100 declarations listed, `limit` (150) rows. `depth` as in `callers`. |
| `rename_plan` | `PlanRename` (with its carried renames), `PlanUnitRename`, `RenameBlockReason` over `LibraryPaths` | The edits of a rename as `line:column` positions of the old text, grouped by file, each row with the line as it reads after the edits on it; nothing is written, the agent applies them (a line with two columns, the last first). PasTree's plan is the contract: the declaration and every resolved use (a namesake is left alone, an overloaded routine renames only the one addressed - a name that is several is refused with the candidates, as everywhere), the class name in its methods' implementation headers, the paired parameter names of a forward or implementation header, every link of a property's redeclaration chain, the form-file lines that bind it by name (tagged with the component and the property), and for a component the handlers named after it, carried along under their new names as the form designer does - an edit that is not the new name shows `(old -> new)`. A method takes its family under the new name, said in a line naming each and its tie (PasTree 0.86.0, `RenameFamily`): the methods of its VMT slot - from any of them, the root included (E2137 at each override otherwise) - the interface methods it implements and every implementation of them, through a class listing the interface or one extending it (E2291 otherwise), and a descendant's hiding namesake that calls it by a bare `inherited;`, both ways - the one break no build reports: renamed alone, that inherited compiles and calls nothing. Before 0.24.2 none of the three was followed: on the client group an interface method's plan left its implementing class (5 edits of 7), and a settings frame's change handler planned 15 lines where 39 in 6 files keep the descendant frame's controls reaching it; both now build, and 3 of this server's own virtual methods, renamed as planned, too. Over 40 overrides sampled from the client group's own units every plan was short before - 82 edits in all, 5,340 now - the largest a slot of 243 methods (490 edits in 103 files) and one of 289 edits in 79 files, both of which build as planned; 0.55 s a plan on average, 1.1 s the largest (the family's uses are one pass over the closure: a pass per member was 10 s). Refused whole where the ties, matched by name, would guess: an overloaded name in the family, a slot whose root has no source, a member in a library or read-only file (an override of `TObject.Destroy`). A unit (its name, or its file) is its header and every `uses` item; the file name it needs is said, the file is not renamed, and what names the file is planned with it - the file name in a `.dpr`/`.dpk` item's `in '...'` path (PasTree 0.87.0) and in each member's `.dproj` `DCCReference`, their directories kept. Before 0.24.3 both kept the old name: the server's own `PasMcp.Log` renamed as planned, its file renamed as asked, stopped at F2613, and the `.dproj` this server reads its unit list from named a file that was gone. **Refused whole**, as PasTree does, with the reason and nothing planned: a name that is no identifier or the same, a source under the library paths or read-only, a binary or unreadable form file, a published property or enum value a form spells, a unit whose text cannot be read back to check its uses (its file changed on disk since the analysis, PasTree 0.97.0), a `uses` alias. An analysis that refuses refuses the plan; the shared units of a group, analyzed twice under the strict policy, are planned once (edits merged by site). Not in the plan, and said: the lines of branches the configuration does not compile that write the name (to check) - every place, a row each with its line, from PasTree's `AInactive` beside the plan (0.29.2; PasTree 0.97.0 refused the whole plan at the first such place instead, which left the agent the rename to do by hand and one line to go on - never a refusal again), the root `Name` through which other forms reach a module's components, and that a collision with a name visible at an edit is not checked - `compile` says. `limit` (2000) caps the source lines, and a cut plan says it is not the whole rename. |
| `change_plan` | `RenameFamily`, `CollectReferencesOfAll`, the walk of `callers`, `RoutineImpl`/`GotoImplementation`, `BareInheritedTarget`, `FindFormSites` | What a change of a routine's parameters or result must touch, before the edit. **Signature**: the lines that change together, each a declaration row tagged with its type and tie - `[TCircle, the same virtual method]`, `[IShape, the same interface method]`, `[TFoo, tied to it by a bare inherited]`, `[TFoo.Item, property - its getter]`, the interface method a resolution clause maps to it - and below it the implementation header, joined over its lines; the errors one left behind gives are named from the ties there are (E2037 at an implementation header, E2137 at an override, E2291 at an implementing class). The family is the one `rename_plan` takes along (PasTree's `RenameFamily`): the ties dcc checks by name it checks by parameter list too. **Calls**: every reference to any member of the family, in one pass over the closure (`CollectReferencesOfAll` - a reference scan per member was a pass each, and a base form's FormActivate on the client group has 69), each a call of the member it binds to - no virtual or interface method is climbed to, since those are members themselves - plus each member's own bare `inherited;` that runs another (`[bare inherited]`), grouped by the routine they sit in, the call's arguments joined over its lines. A property read or write runs its accessor (`via`). **Said, not listed**: the form lines binding it to an event, by file and line - the event calls it with that event type's parameters and dcc does not read a form file, so a changed signature builds and is called wrong at run time; references handing it on (`[not a call]`) to an event or a callback, whose procedural type must change too; an `exports` entry; the other overloads of its name, to which a call may fall after the change without an error; a member a library declares (an interface method of a library interface), which fixes the signature. Where `RenameFamily` refuses - an overloaded name among the ties, a slot a library or a compiled unit introduced - the plan is the routine alone with the calls `callers` finds through its virtual and interface methods, and says which: a library's virtual method fixes the signature (a new one is a new method), an overload's ties pair by parameter list and are not followed. A routine of a library is refused (not this project's to change), anything but a routine is refused, an overloaded name is refused with its candidates (`file` + `line`). The uncompiled branches naming it are lines to check, as in `rename_plan`. `limit` (500) caps the call rows; `limit: 0` gives the counts. |
| `compile` | none: MSBuild (a `.dproj`) or dcc (a bare `.dpr`/`.dpk`) as a process of its own; `impact`'s member closures for which members; the tree for the routine of a row | The members a change reaches, built by the real compiler: those named (`member`), those compiling `file`, else those the files changed this session reach (what the freshness check of section 5 found). MSBuild over the member's `.dproj` with its platform and configuration, target `Make` - `Build` also runs AutoIncBuildNumber, which rewrites the `.dproj` of a project that increments its build number; a bare `.dpr`/`.dpk`, dcc directly with the member's paths and the registry search path. Every output - exe, dcu, bpl, dcp, hpp, obj, resources, type library - goes to the member's build directory (`--build-dir`, default `%TEMP%\pastree-mcp\<group>-<hash>\<member>-<platform>-<config>`), and pre- and post-build events are not run: the answer names them. The first build seeds the dcu directory with the developer's own `.dcu` files, from where MSBuild evaluates `DCC_DcuOutput` to (a probe: a target that does nothing, at diagnostic verbosity), so dcc recompiles what changed since, as the IDE's Compile would. The environment is rsvars.bat's plus the IDE's own variables, which the library path names. The answer: per member, built or FAILED, the time, dcc's line count and the exe; the errors, own files first, each under its file with the routine it sits in and the source line below; an F2063 (could not compile used unit) folded under the unit whose errors caused it; build errors that are not the code's (MSBuild's own, a resource or type library tool); the search path directories that do not exist when a unit was not found; then the warnings and hints of the group's own files that are new since the member's previous compile, the rest counted. New is per unit, since `Make` reports a unit's warnings only when it recompiles it: a unit recompiled has its stored warnings replaced, one not recompiled keeps them, and a unit never compiled here before counts as new only in a file changed this session. `show: warnings` lists every warning of the group's files, `all` every hint too; library units are counted only. dcc cuts a message's `file(line)` at 128 characters, and MSBuild then does not see it as an error at all: the file is found by the prefix, the line by the name the message quotes when exactly one line writes it. A form file dcc does not link has no `file(line)` either: E2161 `Error opening file "<path>"` of a text form that does not convert is put on the `.dfm`, at the line PasTree's reader - TReader's grammar, which dcc's conversion follows - stops at, with its reason, and E1026 of a missing one on the `{$R *.dfm}` of the unit linking it (0.23.1; both were rows under "(no file)", a path in the text). A build that stops at dcc's own internal error - an F2084, no error of the code beside it - is run once more, a Make over the .dcu files the first one wrote: the compiler failing, not the code, and the second usually passes; the answer is the second build's, the first one's error said on the member's line (FR.4: a colleague's build failed once with F2084 in a unit the change did not touch, and passed on the second). The second build deletes the `.dcu` of each unit the error names first, a stale one being the usual cause. One that stops at it too - the same unit or another - is followed by a rebuild in the same compile, and the answer says the three (0.29.1: on the client group a constant's new value made two Makes stop at F2084 in two units of a large implementation `uses` cycle, each a little further on - what looked like a Make not converging in a recompile trial was this chain, its script counting `error E` only; every Make that ended without an error there left nothing for the next one to compile, and a breaking change failed in the first Make to reach its user. 0.29.0 answered "FAILED, `rebuild: true`" after the second Make, and a rebuild or a third Make passed; 0.24.4 to 0.29.0 rebuilt on the next compile only, after a note; 0.23.0 did not build a second time: on the client group's COM server the F2084 came back on every compile, and the Make retry was a whole build more each time - and then the agent called `rebuild: true` on the answer's hint, which passed, a round trip later). A rebuild that stops at it too leaves a note in the build directory, and the next compile stopping at the same error (the code and the files it names - not the text, an access violation's address changes) builds once and says the compiler fails on this code, worked around in the unit it names. A build that passes clears the note, `rebuild: true` always retries. A failure at the internal error says so on the status line itself ("FAILED in 9.1 s, 1 error - dcc's internal error, not the code: `rebuild: true`"), not only on the line below, which an agent read past. The exe is named with a note that it is built to check the compile - not beside the DLLs and files the project's own output has, so run it only if it is a console test runner (an agent ran a COM server built there, and a system dialog came up). Progress notifications while it runs, when the call carries a token; the other calls are answered while it builds, and a cancelled call kills the build (section 7). `limit` (60) caps the rows. |
| `related` | `TypeAt`+`FindDescendants`, `MethodAt`+`FindOverrides`, `InterfaceMethodAt`+`FindImplementations` / `InterfaceAt`+`FindInterfaceImplementors`, `AssignableAt`+`FindAssignments`, `ClassAt`+`FindCreations`/`FindDestructions` | The `...At` test runs at the declaration site - it normalizes (method to its declaration, alias to its type) and refuses what the relation cannot mean, which becomes an error naming what was needed. Rows are grouped by file like every answer; a descendant names its parent (`<- TParent`) below the first level, and a tagged row whose source line repeats the previous row's (an override chain is one signature) shows only its tag. An indented tree was tried first: it repeats a path per row and cost as much as grep on a 250-class hierarchy. |
| `outline` | `PasModuleOutline` | Sections, uses, includes, types with members, routines with signatures, each with its line. `owner` and `section` filter; `members: false` keeps only types and bodies. A routine's or property's parameter list and result are rebuilt from the tree, whole: PasTree's `Detail` is an editor's hint cut at 80 characters, and a cut mid-name followed by the result type - `AInterfa...: TPasTree` - reads as one more parameter. The same text and the same 160-character cut at a parameter boundary as a declaration row; on the client group a 22,000-line form's outline grew 1.2%. `limit` (300 rows) bounds it: over it, the types' members are left out first and the answer says how many (`owner` gives one type's back), then the rows are cut and counted - the client group's largest shared unit was 11,202 rows, about 141k tokens, in one answer, and 400 rows of it without members still 7k. |
| `diagnostics` | model `Diags` | Own units by default. Each unit reports from ONE analysis - its owner (section 4) - so a unit analyzed under two configurations does not report twice. Over the limit, a per-file count comes first. |
| `unit_deps` | `UsesList`, `NodeSite`, `FindUnitReferences` | Uses resolved to files, implementation-section ones marked; used-by merged across analyses. |
| `defines` | the preprocessor's `DefineRefs`, `Skipped` regions and `IncludeRefs`, the raw token stream, `BaseDefineNames`, `FindDefineReferences` | Conditional compilation as the analyzed configuration compiles it. **`file` + `line`**: whether the line is compiled; each `{$IF}`/`{$IFDEF}`/`{$IFNDEF}`/`{$IFOPT}` block around it, outermost first (through the `$I` an include file was read through), with the branch the line is in (`its {$ELSE} at 20`), taken, not taken or not reached, and why - for each name the block tests, the unit `$DEFINE` or `$UNDEF` in effect at the directive (file:line), the project's defines, the platform's predefined set, or nothing, and then a project of another analysis defining it and the `$DEFINE` of it that does not reach there; for an `{$IFOPT X+}`, the switch's value at the directive and what set it (`OptionsAt`: a live directive at file:line - after a `$POPOPT`, the one that set the restored value - the project's switches, dcc's default), and a member sharing the analysis whose own switches start it otherwise; then the symbols in effect at the line (the units' own by the file of their `$DEFINE`, the project's, the platform's, those a `$UNDEF` cancelled) and the compiler options in effect there in switch form: those the project set, then those a directive set, by the file of the directive with its line as the `$DEFINE`s are (`options set by the project: L- Y-; in common.inc: O- 7, R+ 16 - the rest at dcc's default`; one include of the client group sets 13, and every option listed beside them doubled the answer), or every option (`A8 B- C+ ... SCOPEDENUMS OFF RTTI INHERIT VARPROPSETTER OFF`) when nothing set any. In an include file the options are those at its `$I`, where PasTree counts every switch of the include. A branch is taken by what the preprocessor did, never re-evaluated: the first token in it outside a nested block is in a skipped region or not, or, for a branch of directives only, a name in one of them was live. **`file` alone**: its lines not compiled, the outermost branch of each nest by line range, with the same why. **`name`**: per analysis whether the project or the platform defines it, the `$DEFINE`/`$UNDEF` lines in the code, and every directive of the group's files naming it - a test with whether its branch is compiled, a `$DEFINE` with whether it is live - a library's counted; `file` narrows the rows. A shared analysis is built with its first member's defines: where a member of it that compiles the unit has other defines for a name a block tests, it is said (`AppB does not define FIXTURE_A, the analysis takes AppA's defines - built as AppB, it is not defined here`). Each analysis reading the file answers; analyses that agree are one answer, the symbols in effect said apart. A `symbol` no declaration matches that is a conditional symbol says to ask `defines`. `limit` (100) caps the directives of `name` and the branches of `file` alone. |
| `lint` | each model's `UsesList`, `ExtRefMap` and `RefMap` (what a name binds to, and whether before `implementation`), the interface scope's names (`EnumScopeDeep`), the `uses` graph from each program of an analysis, the `Skipped` regions, the unit's form file (`PasDfmLoad`) | Rules `unused-uses` and `uses-to-implementation` (9.7) over the own units, `rules`, `file` and `in` narrowing; an entry is judged over every analysis holding the unit, and one that uses a name of it keeps it. A name counts for the unit listing it when dcc needs that unit in scope to bind it: a unit-level declaration of its interface, an enum value, a member of a helper it declares. A member reached through a value or a type does not - `List.Add` needs no `uses` of Classes; the type written does. Counted too: the qualifier of `Unit.Name`; the unit's form file naming a class or a module the unit declares (`PopupMenu = dmData.pmMain`: the designer keeps that unit listed); a name bound to a unit not listed - PasTree binds an alias of the same name through to what it names (`TModalResult` of Vcl.Controls to System.UITypes) - credited to each listed unit declaring the name; and a name of the interface bound to a unit of the implementation `uses`, which dcc does not search there and PasTree 0.91.1 does, credited to the interface units declaring it. PasTree's own rule (`PasTree.Sema.Lint.FindUnusedUses`, 0.93.4) is asked too, for the units `file`/`in` select, and an entry it finds used in an analysis is used and offered for neither rule: a unit an inline routine called here needs to be expanded (without it dcc does not inline, H2443 - System.UITypes for MessageDlg), and the unit of a class a form file streams, of each ancestor of it, and of a component an inherited form holds - the designer puts those back into `uses` on save. Said at the end of a row, as `but ...`: the units with initialization, finalization or a `{$R}` resource that removing the entry leaves out of a program, no other path of it reaching them; the same for the entry removed together with every other unused-uses row that has no `but` - an agent acts on the rows at once, and each may be safe alone while all are not (so the rows of every own unit are weighed, whatever `file` and `in` show); a branch not compiled here naming the unit or a name of it; a name bound to nothing that the unit declares; a routine of another unit called here that the unit declares too - dcc picks among the same-named routines of every unit in scope, and the index's pick may not be its (on the client group `Trim(ShortString)` took AnsiStrings' Trim, not the SysUtils one the index bound, and removing AnsiStrings added two W1057); for a move, the implementation bindings the unit would take over, searched first once listed last. Said on a move row, not as a `but`: the `{$IF}` blocks the entry is written in (`it is inside {$IFDEF X} at line 27 - move it with its condition`) - moved bare, it is compiled where it was not. A program whose project's defines differ from its shared analysis' (section 4) is weighed in two graphs, each whole: the analysis' `uses` edges, and the same without the entries of own units written in a block that names a define the two disagree on - the ones it may not have. Checked against dcc on the client group (9.7). |
| `metrics` | per own unit, the ranges of its interface declarations (the items of `nkInterfaceSec`, an overload set or a forward and its full declaration one by name) and of the bodies part of them (`Nav.RoutineImplNode` of an inline routine, of every method of a generic type, of an inline method); each model's `ExtRefMap` and `RefMap` placed in them; each model's `UsesList`; `lint`'s rows for `cycles` | `recompile` (9.7): a graph of the own units' interface declarations - a reference into one of another unit's declarations (a member's counts for its type) makes the referring unit a binder of it, and a reference inside a declaration or a body part of one makes that declaration take the other in, in its unit too. A change to a declaration recompiles its binders and changes every declaration taking it in, transitively; a unit's is the same from all of its declarations. `symbol` (a member names its type, and a routine's row says its body alone recompiles its unit), `file`, or neither: the own units ranked by it, from per-declaration unit sets computed once over the components of the graph (bitsets). A unit several analyses hold is counted over all of them, by file; each program of an analysis with the units of it recompiled. `cycles`: the strongly connected components of the own units' `uses` graph, those of one analysis contained in a larger one of another folded into it with its programs; per cycle its entries, the shortest way round through the unit asked or the most connected one (`->` interface, `~>` implementation), and the entries `lint` finds unused on it - the binding walk over the cycle's files first, PasTree's rule only for the files where it found one - with the largest cycle left without those that have no `but`. `limit` |

What comes next - new tools and changes to these - is section 9.

## 4. Project groups

A `.groupproj` lists `.dproj` (or bare `.dpr`) members. The client group has
nine, 7,700 units in all; pastree-lsp's one-process-per-project shape costs
3.5-4 GB per member there, which does not fit.

**An analysis** (`TMcpAnalysis`) is one `TPasSemaProject` whose roots are the
main sources of one or more members. `TPasSemaProject` caches units by full
path, so members in one analysis parse their shared closure once.

**Which members share an analysis** is the group policy:

- `shared` (default): one analysis per platform. Its defines and switches
  (the `.dproj`'s DCC_* options as dcc's `-$` switches, and `-CC`), and the
  last word on aliases, come from the member that creates it - members are placed
  LARGEST FIRST (most listed files). That order is load-bearing: in file order
  a one-file helper project created the Win64 analysis, the server project ran
  under the helper's defines, took client-only `{$IFDEF}` branches, and
  reported 170 unresolved units and 8,000 errors its own build does not have.
  Every member whose defines or switches differ from its analysis' is
  logged, and `defines` says it where they decide a branch.
- `strict`: one analysis per distinct (platform, defines, namespaces,
  aliases, switches, `-CC`). Exact.
- Under both, a member listing a DIFFERENT file for a unit name already pinned
  in an analysis gets a new one: an analysis can hold one `Foo.pas`.

Measured on the client group (RAD Studio 13.0, 32 GB machine; light mode,
the default since 0.31.0, against `--no-light` - section 9.9):

| Policy | Analyses | Units | Load | Held |
| --- | --- | --- | --- | --- |
| shared | 3 | 3163 + 1680 + 393 | 3.9 s | 1.5 GB |
| shared, `--no-light` | 3 | 3973 + 2256 + 522 | 6.9 s | 2.8 GB |
| strict | 9 | 3086 + 1666 + 1078 + ... | 6.5 s | 2.2 GB |
| strict, `--no-light` | 9 | 3782 + 2134 + 1467 + ... | 12.5 s | 4.6 GB |

Search paths of an analysis: every member's directory, every member's
`DCC_UnitSearchPath`, then the installed library (registry `Search Path` and
`Browsing Path` of that platform, macros expanded, then the Studio source
trees). Every member's listed `.pas` files are pinned (`PinUnitFile`).

**Owner analysis.** Each own file has one: the analysis that lists it (lowest
index first, analysis 0 holding the largest member), else the first that
reached it. Diagnostics come from the owner only.

**Own vs library.** A file under the group directory, or listed by a member,
is own - but for one under a tree `--light` names, which is library. Everything
else is library: not watched, demoted after every build, listed after own
files, and read interface-only where it lies in a library tree (9.9).

## 5. Freshness

The agent edits the files it asks about. An index that answers with the line
numbers of the previous version is worse than none.

Before every call except `status`:

1. A changed `.groupproj`/`.dproj` reloads the workspace.
2. Every own file of every analysis (each model's main file and its `$I`
   includes) is compared by write time and size with what was recorded at
   the last build or module run - about 60 ms per call on the client group
   (2,500 own units plus includes, across three analyses).
3. A changed unit is re-analyzed alone (`AnalyzeModuleOnly`) - PasTree
   re-parses it and re-runs its passes if its interface did not change in a
   way that reaches other units. What that run takes in - a unit a changed
   uses clause adds, an include the unit now pulls in - is stamped after it
   and named in the note (`added:`); unstamped, its later edits and its
   deletion went unseen until some full rebuild - a new unit that no longer
   compiled read clean.
4. Refused there, a changed include, or a deleted file: that analysis is
   rebuilt with the previous one as its parse donor (`AdoptParseDonor`), so
   only changed files are parsed again.

Form files are PasTree's to re-read: every query revalidates each by size and
time, and a unit directory whose write time moved is listed again, so a form
file written after its unit - an agent's order - or brought back by a
checkout is a form file of the project at the next call. The workspace keeps
the same stamps (each own form file, each own unit directory) only to name the
change in the note.

What this does not see: a new unit file that nothing `uses` yet (not in any
closure until a unit names it - then the naming unit changed, and the rebuild
finds it), and library files changing (not watched on purpose).

## 6. Memory

Library units are read interface-only (light mode, 9.9): no bodies are held
for them unless a query needed them (made full inside the query; an
escalation makes the whole analysis full, and it stays so). After every build `DemoteText` frees the
text layer of every library unit and keeps own units warm. Library positions and snippets come back through
`EnsureHydrated` when a query needs them; own units must stay warm because
`AnalyzeModuleOnly` refuses a demoted model. Queries re-hydrate library units
over time; the next build demotes them again. A periodic re-demotion is an
open question (section 8).

## 7. Protocol

MCP over stdio: one JSON-RPC message per line, UTF-8 (not LSP's
`Content-Length` framing). Methods: `initialize` (with `instructions` - what
the tools are for and when to prefer them over grep; Claude Code shows this to
the model), `ping`, `tools/list`, `tools/call`. Of the notifications,
`notifications/cancelled` is acted on (below) and the rest are ignored.
Revision `2025-06-18`; an older one a client asks for is echoed. A
`tools/call` whose params carry `_meta.progressToken` gets
`notifications/progress` from a tool that reports - `compile`, as a member's
build starts and every 5 s while the compiler runs. Claude Code aborts a call
to a stdio server that sends neither a response nor a progress notification
for 30 minutes (its MCP documentation; `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`
changes it), and its wall-clock limit is about 28 hours.

The initial analysis runs on a background thread, so the handshake is
immediate. A tool call waits for it up to 100 s, then answers "still loading"
with `isError`.

Threads (0.9.1). The main thread reads stdin and answers `initialize`,
`ping` and `tools/list` itself. A `tools/call` goes to a queue that one
executor thread runs, a call at a time in the order they came: the index is
read by that thread only. Queries are not read-only - they hydrate library
units (section 6), the freshness check re-analyzes changed files and replaces
the navigator - and PasTree's query paths are not made for two readers; with
calls of 60-500 ms against a model turn of seconds, running them side by side
would buy little for that risk. The one tool that takes long is split
instead: `compile` chooses its members on the executor, builds on a thread of
its own that reads nothing of the index, and answers back on the executor. So
the calls behind a build are answered while it runs, and its answer may come
after theirs - JSON-RPC matches an answer to its request by id. Writes to
stdout are serialized, a message at a time.

A cancelled call (`notifications/cancelled`) is not answered, as MCP asks:
dropped while queued, its answer suppressed once running, and a build's
process tree killed - on the client group within 0.2 s of the notification,
the dcc and MSBuild of a 17 s build both gone. Two builds of one member, from
two sessions or two calls, take turns on a named mutex.

stdout carries protocol only. The log goes to stderr (Claude Code keeps it)
and to `<project>-pastree-mcp.log` beside the project.

## 8. Open questions

1. **Default policy.** `strict` is exact and costs 1.6 GB and 7 s more on the
   client group. If that is affordable everywhere this runs, it should be the
   default and `shared` the option.
2. **Does the agent use it well?** The real test is an agent on a real task,
   compared with the same task without the server: tokens, turns, and whether
   the answers were right. Whether the answers are right is measured now
   (section 10); a first pilot of tasks (10.4) was solved as well without
   the server, so whether the tools are enough where grep is not is still
   open. What 10.4 did show is that an agent not told about the index often
   does not call it - 5 runs of 12, the wrong answer in one that grepped.
   Serena, an LSP-backed MCP server, found the same with Claude Code and
   denies a run of greps from a hook. `--hook` (0.45.0, README "The grep
   hook") does that here: a search for a name over Pascal sources, or a
   `sed` line range of a Pascal file, is denied once with the call that
   answers it, then let through when repeated - a text search is still the
   agent's to make; at most once per 10 minutes and not within 5 of a
   pastree call. Denied rather than added beside the result
   (`additionalContext`): an agent holding the grep's answer has no reason
   to ask again. Whether it brings the tools arm up to the hint arm is the
   next run of 10.4's tasks.
3. **Tool descriptions.** They are what the model decides by; wording them is
   empirical. Adjust after watching real sessions.
4. **Re-demotion.** Library units hydrated by queries stay hydrated until the
   next build. Measure how much that grows over a long session.
5. **Result caps.** 150 references and 60 diagnostics by default are guesses.
   Over 384 sampled symbols on the client group (section 10) 150 rows put
   24 answers about library members at 5.0-6.3k tokens; `outline` and
   `form` were measured to 300.

## 9. Planned

The tools of section 3 answer "where is it". What an agent still pays for,
across the usual tasks - finding a bug, adding a feature, refactoring,
optimizing - is three things this section goes after:

- **Reading to extract one piece.** A whole unit opened to see one routine,
  an outline per ancestor to learn what a class can do.
- **The compile loop.** Hundreds of lines of MSBuild output read to find
  three errors, then files re-read to understand them.
- **Checking that a change is safe.** Who calls this, who overrides it,
  which forms bind it, which projects must be rebuilt - four or five calls
  and a grep today, and the grep still misses the `.dfm`.

Everything here is a plan, not a contract. Section 8, question 2 comes first:
two or three real tasks on the client group, read back from the transcripts,
will say where the tokens actually go and may reorder this list. Section 10
reordered it once by what the answers got wrong (9.8). Each item
gets its questions in a `.bench` file (README) before it is built, so its
answer is measured against grep and against the calls it replaces.

### 9.1 Rules for every new tool

These follow from section 3 and from what the sibling projects learned; they
are here so a new tool is not the one that breaks them.

- **Addressed like the others.** `symbol`, or `file` + `line` + `name`;
  ambiguity lists candidates; errors the agent can act on are `isError`
  results. A tool that invents its own addressing is one more thing the
  model gets wrong.
- **Answered like the others.** Relative paths, grouped by file, one trimmed
  line per row, a cap with "N more", own files first; a header that counts
  every row, and `limit: 0` for the counts alone. Look at the tokens
  (`--script`) before and after: a tool whose answer costs as much as the
  grep it replaces is not a win, however right it is - the indented
  descendants tree of section 3 was exactly that.
- **The server never writes the agent's files.** Plans are lists of edits
  the agent applies. The one tool that writes anything (`compile`, 9.4)
  writes only to its own temporary directory.
- **The index from one thread.** A tool reads the index on the executor
  only (section 7). One that takes long - a process, a network - is a
  deferred tool: it takes what its work needs from the workspace first,
  works on a thread of its own touching neither the workspace nor a PasTree
  model, and answers back on the executor. A race here is silent: a wrong
  answer now and then, or an access violation no smoke run repeats.
- **Fresh like the others.** Every call but `status` goes through section 5
  first; a new input a tool reads (a `.dfm`) is watched the same way, or the
  answer is the previous version's.
- **Text is read through one place, and assumed to carry a BOM.** Delphi
  writes UTF-8 with a BOM by default, so a leading BOM is the common case and
  never content. pastree-lsp lost an investigation to a hand-rolled read: one
  BOM made a whole file resolve nothing while the log said only "no
  identifier". A `.dfm` adds a second trap - it may be binary (9.5).
- **Says what it did not see.** An empty answer names the other ways the
  thing is reached (through a base, a form file, a branch not compiled); a
  cut answer drops the least telling rows first and says what it dropped.
  Nearly every serious defect section 10 found was an answer wrong without a
  word - "0 references" read as dead code.
- **Covered by the smoke test, empty cases included.** A new model-walking
  handler gets a `tests\smoke.calls` row over the fixture, and one over an
  input where the walk finds nothing (a type with no members, a routine with
  no callers). pastree-lsp shipped an access violation on an empty scope
  that no request had exercised.
- **A new tool or a changed contract is a MINOR version** (CLAUDE.md), and
  the `initialize` instructions and the tool description say when to prefer
  it - that text is what the model decides by (section 8, question 3).
- **A library fix it depends on raises `cMinPasTreeVersion`** when its
  absence would be a wrong answer rather than a compile error.

### 9.2 Reading less

1. **Enclosing routine on every reference row** - done in 0.3.0: "Where a
   row sits", section 3. It needed no PasTree change: `RTEnclosingRoutine`
   is private, but it only climbs `Nodes[].Parent`, which is public.
   Measured on the client group (the 22 questions of the layer 1 bench):
   about 5 tokens more per row where rows share routines (1,245 references
   of an interface: 20.7k -> 27.0k tokens), about 10 where every row has a
   routine of its own (11 callers: 335 -> 452); the whole bench 60.5k ->
   67.3k, still 11x below grep with context lines. Time unchanged.
2. **`source`** - done in 0.4.0, section 3. `members: false` for a type was
   left out: `outline` with `owner` already lists a type's members with
   their lines. Measured on the client group: an 11-line constructor 123
   tokens, a 301-line method 3.9k, a 57-line class 0.7k - what reading
   exactly those lines costs, a floor an agent without the server does not
   reach, since it cannot know where a routine ends; a 6-line routine 104
   tokens where `definition context: 25` took 365. One call where there
   were a search and a read.
3. **`members`** - done in 0.6.0, section 3. No PasTree change:
   `EnumMembersX` walks the members the way `FindMemberX` looks one up. The
   default reach is not "everything": an ancestor's private members, which
   its own methods cannot use, were 46 of a form's rows, and the VCL behind
   it 640 more - hence the reach rules and the library count. Measured on the
   client group (the members questions of the layer 1 bench; the baseline
   reads each own class declaration of the chain exactly, a lower bound, and
   `also` is an outline per class, what the server offered before): a form
   over five own ancestors 1.8k tokens in one call, where the reads cost 3.0k
   and the five outlines 3.9k - after finding the ancestors, one `= class(`
   grep per level; a record class over four 2.9k against 4.4k and 17.7k; the
   107 properties of an interface over three 2.1k against 5.5k; the members of
   a base form with `Layout` in their name 258 tokens against 1.8k of grep; a
   variable of the form type, what its unit can call, 1.0k. 50-120 ms a call.
   A variable's header names its type, which is half of `type_of` (4).
4. **`type_of`** - the type of an expression or variable at a position, with
   the doc comment of what it resolves to (`WithTargetTypeX`, `XTypeText`,
   `SymDeclTypeX`, `SymDocComment`). For a local or a parameter, the only way
   to learn its type without reading the routine's header.
5. **Answer size up front.** `references` and `find` take
   `mode: count | files | lines` (default `lines`). A symbol with 900 uses is
   first a count per file; the agent then asks for the lines of the files it
   cares about.

   Done for `references` in 0.26.0 (section 3): `mode: files` is a row per
   file with its count, under its directory, code files first when the
   limit cuts (as code rows are); `in` lists only the rows in files whose
   path contains it or matches it as a wildcard, the header still counting
   all; `count` is `limit: 0`, which came first (0.19.0). `find` was left
   out: its rows are declarations, one per name, and a query too wide is
   narrowed by the name, `kind` or `scope` - none of its answers on the
   client group was one a limit cut for size. Measured there
   (`local/change-bench/m2.out`): TabOrder's 6,355 uses in 867 files are
   85,884 tokens as lines, the file map 6,753 (1,228 for the first 150
   files), and its 303 code rows alone (`in: *.pas`) 6,422 - where the
   default cut of 150 rows was 2,683 and the rest unread; one form's 55
   lines (`in` its file) 890. A method used once or twice a file gains
   less: SetFocus, 370 uses in 156 files, 7,623 tokens as lines, 1,204 as
   the first 150 files; a property of 21 uses 418 against 119.
6. **Several targets per call.** `definition`, `source` and `references`
   take `symbols: [...]` beside `symbol`. Understanding a change usually
   means three to six symbols; each turn re-sends the whole context, so the
   saving is in turns, not in answer tokens.

   Done in 0.43.0 as `targets` - names, or objects with what one call
   takes, so a `file` + `line` or a `lines` piece is a target too - each
   answered in turn under `=== k of n: <target>`, the call's other
   arguments for every one, at most 20. A target that fails says why in its
   place; the call fails only when all did. A string is taken for the list
   it holds (JSON, or names one after another): agents send arrays as
   strings. Measured first: in the client group's sessions of 2026-10-05 to
   10-22, 291 calls of these tools against 1,710 greps and reads of code,
   1,194 of those reading a routine's or a type's text - 793 of the 881
   line-range reads within three calls of a grep, 251 in the same shell
   command (`grep -n`, then `sed -n`) - while `source` was called 37 times.
   46% of the 1,710 asked for more than one target at once (an alternation
   of method names, several `sed` ranges), which one call per symbol made a
   turn each. The same audit gave the other deferred items little: `type_of`
   about 12 searches, `uses_for` 9, `overview` 3, `implement_plan` one or
   two, `scope_at` none. With it, `symbol` + `file` and no `line` narrows
   the name to that file (it addressed the unit), `outline` takes `unit`,
   and `lint`'s `rules` a JSON list written as a string.
7. **`overview`** - the group in one answer: members with platform, own
   units by directory with line counts, the largest units and classes. The
   first call in an unfamiliar group, instead of a directory listing and a
   dozen outlines.

### 9.3 Following the flow

1. **`callers` / `callees`** with `depth` (default 1, capped). `callers` is
   `references` folded to the routines containing each call; `callees` the
   calls made by one routine's body, resolved (`CalleeSyms`, `CallAt` in
   `PasTree.Sema.Complete`). A virtual call lists the overrides it may
   dispatch to, marked as such; an interface call, the implementations.
   Both are what bug hunting runs on - "where does this nil come from",
   "what does Save end up doing".

   `callers` - done in 0.5.0, section 3. No PasTree change: every entry
   point it needs is public. Measured on the client group (the callers
   questions of the layer 1 bench, `also` = the calls it replaces):
   depth 1 costs what `references` costs (11 calls, 449 tokens against
   452); depth 2, 1,029 tokens in one call where `references` took 11 calls
   and 1,151 tokens; an override called only through its base, depth 2,
   143 tokens and one call where `references` answers "0 references" and
   the path takes four; a getter called 32 times from 17 routines through
   the property of an interface its class takes on through an extending
   one, 973 tokens against 1,398 in six calls - where
   `related implementations` answers 0; the 162 bare `inherited;` calls of
   a base method, which no reference search finds, 3.1k tokens. 0.2-1 s a
   call, the upper end a property redeclared 17 times (PasTree's search of
   the chain). What it does not see, and says where it can: an event handler
   a `.dfm` binds (9.5), a call through a method pointer (the
   row that assigns it is there, `[not a call]`), a function passed as a
   callback (taken for a call), a bare `inherited;` in a static method
   hiding another that is not a constructor, an interface method a
   resolution clause maps to a differently named method in another unit.

   `callees` - done in 0.7.0, section 3. No PasTree change: the maps the
   completion engine's `CalleeSyms` reads are the model's own. Measured on the
   client group (the callees questions of the layer 1 bench; the baseline
   reads the body exactly, which resolves nothing, and `also` is the body's
   `source` with `related overrides` for a virtual call - for depth 2 the
   `source` of each routine called too): depth 1 costs about what the body
   costs - a 32-line method 734 tokens against 653, a 301-line form handler
   3.6k against 3.8k - with each call bound to its declaration and each
   virtual or interface call to what it may run: the saving is the lookups
   an agent does not make. Depth 2 saves calls, not always tokens: one call
   where the sources of 13 routines took 15, at 5.5k tokens against 3.0k for
   a method whose base-class hooks fan out; a getter chain three deep, 306
   tokens against 3.2k in six calls. 0.2-0.4 s a call, most of it the class
   index the first dispatch builds. The dispatch search counted classes
   examined first and gave up past 100, which hid a two-override list under
   a 250-class tree: it now examines up to 5,000 and caps the methods found.
2. **Access kind on references.** Each row tagged `read`, `write`, `var`
   (passed to a `var`/`out` parameter), `addr` (`@X`) or `call`; `access`
   filters. "Who changes `FState`" is then one call; `related assignments`
   covers direct writes only, not `var` passing.
3. **`impact`** - given symbols, or a unified diff (the agent passes
   `git diff` output; the server does not run git): the routines the diff
   touches, their callers to `depth`, the overrides and interface
   implementations bound to them, the units that use them and **which group
   members include those units** - so the agent builds and tests the
   projects the change reaches and not the rest.

   Done in 0.8.0, section 3. No PasTree change. The member list is not
   "every member of an analysis holding the unit": an analysis holds several
   members and its models are their closures together, so each member's own
   is read from its main source through `uses` - 2 ms for nine members on the
   client group. Measured there (three questions, `also` = the calls it
   replaces): a four-file diff that adds a virtual method and moves three
   callers onto it, 1.8k tokens in one call and 2.5 s, where `callers` of the
   four routines, `related overrides` and `unit_deps` of the two changed
   interfaces took 2.3k in seven calls - and none of them names the six
   members out of nine that compile it; a method with 149 overrides, 3.2k
   against 5.3k for `callers` and `related overrides`; a 20-file diff of 88
   declarations, 5.1 s and 5.8k tokens, nearly all of the time the reference
   searches of its 40 roots. The first draft listed the class of every member
   edited in it and every user of that class, and the importers of each
   changed interface by name - 200 of them for a core unit - at 7k tokens for
   that diff.

### 9.4 Closing the compile loop

**`compile`** - build the member that owns a file, or a named member, with
the real compiler (MSBuild over the `.dproj`, the member's own platform and
configuration), and answer with its errors, warnings and hints in the shape
of `diagnostics`: relative paths, grouped by file, de-duplicated (one missing
unit repeats once per importer), capped, errors first. `hints: false` by
default.

- **Without arguments: what changed** - the members compiling the files
  edited this session; none edited (or `base` given), the files git reports
  changed: not committed, and the branch's own commits since it left `base`
  - by default the remote's default branch (`<remote>/HEAD`, the remote the
  branch tracks, else origin). Both parts, each counted, and the base and
  its commit count named; past 20 commits the answer says to pass `base`.
  No branch names are guessed (0.41.0): 0.40.0 picked the nearest of
  main/master/develop/release/*, a convention of one repository - the
  agent knows the branch it works from, from the user or from git, and
  passes it. A field report: a branch off release/... diffed against the
  default branch took in the whole release, and a change part committed,
  part not, built only what the uncommitted part reaches (0.34.0). A
  refusal says whether git had nothing changed or nothing to say.
- **What an incremental build did not compile again** still has the
  warnings and hints the last compile here reported for it (0.39.0): they
  count as old, and `show: warnings` lists them tagged `[earlier
  compile]`. dcc reports only what it compiles, so a build after a build
  answered "no errors, warnings or hints", and `show: warnings` after
  "1 old warning, not listed" listed none (a field report).
- **A bare .dpr is built with `-M`** (0.42.1), as MSBuild's Make builds a
  `.dproj`. Without it dcc compiles the units but writes no .dcu: every
  build compiled every unit, no unit was known compiled, and what is new
  per unit (below) had nothing to go by - the warning of an unchanged unit
  came back both as reported and as kept, and the second compile of a
  member with a warning was an internal error.
- **`code`: whether a construct compiles here** (0.42.0). The text given -
  a program, a unit, or statements alone, put in a program of the server's
  own with System.SysUtils used - built by dcc directly with a member's
  settings as the index read them: its platform's dcc (dcc32 for one that
  is not Win64), defines, search path, namespaces, aliases and `-$`
  switches, then the directories of the own units the index holds for it (a
  bare .dpr names them only in `uses ... in`), then the registry search
  path. So the code may use the member's units - statements by a `uses`
  clause first, which joins the program's (0.44.1; compiled as a statement
  before, E2029). It builds in a directory
  of its own beside the member's (`snippet\`), with `-M`: without it dcc
  compiles the units but writes no .dcu, and every call would compile the
  member's units again. Errors come by the line of the code as given, not
  of the program around it. Compiled and linked, never run. Why: language
  questions in the sessions that built PasTree and this server were settled
  by compiling a probe, rarely by the web - where the docwiki is silent on
  the edge cases, and an answer found there was once quoted wrongly. The
  compiler of the project's own version is the one source right for it.
  With it, the server's instructions and `status` name that compiler, its
  Delphi version, the constructs of later versions it rejects (from 10.3 on:
  inline variables, managed records, binary literals and the digit
  separator, multiline strings, if-expressions, NameOf, `is not`/`not in`,
  `{$PUSHOPT}`, noreturn) and the language reference - one line, paid by
  every session, against code written for a newer compiler than the
  project's. The constructs its own version added are named too (0.43.2):
  on the newest compiler nothing is rejected, and an agent on the client
  group, unsure of if-expressions and `is not`, compiled a probe to learn
  they were there.

- **Output goes to a temporary directory** (`DCC_ExeOutput`, `DCC_DcuOutput`
  overridden), never to the project's own output: an agent's check must not
  replace the binary a developer is running, nor leave `.dcu` files from
  another compiler version where the IDE will find them - they are not
  portable between compilers (CLAUDE.md).
- **The compiler is the truth.** PasTree's diagnostics are a fast
  approximation and can differ. `compile` exists so the agent trusts neither
  blindly: `diagnostics` while editing, `compile` before saying done.
  The two are also read against each other: an E2003 of a Make whose name
  the index resolves on that line gets the declaration's place beside it,
  and the status line names `rebuild: true`. dcc's Make can read a stale
  .dcu of the declaring unit - on the client group `Undeclared identifier`
  for a method declared and implemented, in the IDE's incremental build
  too, and a rebuild passed with no change; left unsaid, the agent goes to
  declare what is already there.
- **The files on disk, not the IDE's buffers.** The index and `compile` read
  what is saved. An agent editing through an IDE bridge (a colleague's Kai
  setup: the open file's buffer is the truth, edits go to it unsaved) gets
  answers about the old text without a word; the server's instructions say
  to save first.
- **It is slow.** A full build of a large member takes minutes; the
  description says so, one build runs at a time, and the answer reports the
  time taken.
- **Which RAD Studio** is the one the server already resolved (`--studio`),
  so the compiler matches the library paths the analysis used.

Done in 0.9.0, section 3. No PasTree change. What the plan did not foresee
was found on the client group before the tool was written, by building its
members the usual way - MSBuild from a RAD Studio prompt, only with the
outputs redirected so nothing of the developer's was overwritten:

- **The IDE's own environment variables.** The library path names a variable
  for every third-party directory, one the IDE defines for itself (Tools >
  Options > Environment Variables). A command-line MSBuild does not know it:
  the smallest member stopped in 1 s at `F2613 Unit 'JVJclUtils' not found`,
  under 214 "Directory not found" hints - 69 KB of output. `compile` sets
  them as the IDE does, from the registry.
- **The build events.** Nearly every member runs a pre-build tool that
  rewrites a version resource in the source tree, with git calls; the
  server's post-build event runs the new exe to rewrite two JSON files of the
  repository. Not run, and named in the answer.
- **A build from nothing does not build.** In an empty directory dcc
  recompiles every library unit whose source is on the path, and a DevExpress
  unit does not compile under the current compiler: the main member fails in
  5.7 s. The developer's builds work only from their old .dcu files. So the
  first build copies them - 3,847 files, 319 MB, 3.5 s - from where MSBuild
  evaluates `DCC_DcuOutput` to, and dcc recompiles what changed since.
- **`Build` rewrites the `.dproj`** of a project that increments its build
  number (AutoIncBuildNumber runs after it); `Make` does not.
- **dcc cuts a message's `file(line)` at 128 characters**, and MSBuild then
  passes the line on as text: its summary counts only the F2063 that
  followed. The file is recovered by its prefix, the line by the name the
  message quotes.
- **A form file's link error names no line.** dcc converts a text `.dfm`
  and reports one that does not convert as E2161 `RLINK32: Error opening
  file`, the path in the text; a missing one as E1026 with its bare name.
  PasTree's reader stops where dcc's conversion does, so the row goes on
  that line of the form file, and E1026 on the unit's `{$R *.dfm}`.
- **What is new has to be per unit.** `Make` reports a unit's warnings only
  when it recompiles it, so a whole-build comparison would call every warning
  of an untouched unit gone. Hints are listed when new, like warnings, rather
  than left out: a new one is usually the change's own (a local left unused).

Measured there, the answer against MSBuild's console output for the same
build at its default verbosity: a small member (994 .dcu files), 3.5 s and
119 tokens against 41 KB (about 10k tokens) for two warnings in library units
and one of MSBuild's own; the
main member, 16.4 s for the 27,200 lines changed since the developer's build
and 146 tokens against 34 KB for no diagnostic at all - 15.7 s again with
nothing changed, the link of an 80 MB exe; the Win64 server, 17.2 s where
the same build from nothing took 48 s. The source tree was unchanged after
each, ignored files included.

### 9.5 Forms

A `.dfm` (or `.fmx`) binds components to published fields and events to
methods by name. `references` does not see those bindings: an event handler
looks unused, and a rename made from the `references` answer compiles and
then fails at run time when the form loads. For Delphi this is the largest
gap between the answers and the truth.

- **Form bindings in `references`.** A row per form line binding the
  symbol - `OnClick = Button1Click`, `object Button1: TButton` - tagged
  `form`. Unused-code answers (9.7) count them.
- **`form`** - the component tree of one form: names, classes, the events
  each binds and to which method, the published field each component fills.
  What a developer sees in the Object Inspector, without reading the text.
  Measured against a text oracle of TReader's rule over the client group's
  1,043 text forms, four readings were fixed (0.15.0, PasTree 0.66.0): an
  event is `On` and an upper-case letter, never a True/False value (a
  Boolean `OneOnRow` read as a handler that is gone, on 49 lines); `OnX =
  nil` is shown cleared, naming the ancestor's handler that no longer runs,
  not "fails to load"; each item of a collection is its own row
  (`Items[1].OnClick`), and a descendant's collection replaces the
  ancestor's whole; text after the root's `end`, which dcc drops, is said -
  and so is a handler named only there, in `references` and `callers`. The
  row limit is 300 (400 put 7 forms over 5k tokens). A form class with no
  form file of its own - a second class in a form's unit, a unit with no
  `.dfm` beside it - loads its nearest ancestor's: TCustomForm's
  constructor reads the resource of every class up the chain, and a class
  without one adds nothing. `form` of it shows that file, said so, each
  event bound to the method of the name on the class asked about (its
  redeclaration, where it has one), as `callers` already bound it; a unit
  with several such classes names them. It used to refuse with "no form
  file of its own", and the task pilot's agent went to Glob (F6.4, 0.19.0).
- **Needs a form reader in PasTree**, which it does not have. Text DFM is a
  small grammar (`object`/`inherited`/`inline`, properties, collections,
  binary data blocks). Binary DFM must be recognized (the `TPF0` signature)
  and either converted or reported as unreadable - never skipped silently,
  or the answer claims no bindings where there are some. An inherited form
  (`inherited Foo: TFoo`) resolves against its ancestor's form.
- The file is found beside the unit through `{$R *.dfm}`; a unit with that
  directive and no file is itself worth reporting. `compile` puts dcc's
  E1026 for it on that directive (0.23.1).
- PasTree reads and binds form files since 0.59.0 (`PasTree.Dfm`,
  `TPasFormBinder`, `TPasNavigator.FindFormSites`): the rules are TReader's,
  a binary file is converted in memory and listed, and each site says what
  it is (component, class, handler, component reference), on which component
  and how it is reached (own, inline frame, another module's Name).
- Its questions come first: the `forms-*` rows of `tests\fixture.bench`, over
  the fixture's AppF - a data module named from a form, a frame placed
  inline with its button's handler set by the host, an inherited form that
  rebinds a click and binds its parent's handler on a component of its own,
  a binary form file. The bench's `grep-dfm` searches the text form files
  with the sources, one call as a grep with no file filter, and skips a
  binary one as ripgrep does. Measured on the client group before the
  server reads a form: 1,075 form files, 5 of them binary, 846 inherited,
  126 with an inline frame. A cancel button's handler, which no code calls
  and of which `callers` says "none found", is a name written on 261 lines
  of sources and forms, one of them the binding asked about; a panel field
  of one name is declared by 22 classes and reopened by 222 form files; the
  components of the main form are 7,188 lines of `.dfm`, 82k tokens to read
  with the inherited forms behind it.
- **Measured again with the tools built** (0.23.1, the same 9 questions over
  the client group; `local/bench-forms-client-0.23.1.md`). The 9 answers
  cost 7,283 tokens in all against 1,080 before - the bindings they did not
  have - and grep 112,062 (243,032 with the 3 lines of context that tell a
  real hit from a namesake): 33x. The handler no code calls: `callers`
  "none found" is now its one form binding (52 tokens against 5,120 for
  the grep of 261 lines), `references` of a base panel 83 rows (from 2) in
  1,452 tokens, of an inline frame 44 (from 19), `form` of the main form
  3,743 tokens against the 82,153 that the `.dfm` chain takes to read. No
  row of any answer is missing from what grep finds (miss 0 on all 9);
  the first call, which reads every form file, is 0.7 s, the rest 0.15-0.3 s.
  On the fixture the 18 questions of `testsixture.bench` cost 2,042
  tokens against grep's 2,906 (7,069 with context); before the form rows
  the same 18 cost 1,253.
### 9.6 Refactoring and new code

1. **`rename_plan`** (done, 0.24.0; a method's family 0.24.2, a unit's `in` paths and `.dproj` entries 0.24.3, section 3) - `PlanRename` / `PlanUnitRename` as a list of edits
   (file, line, column, old, new) the agent applies itself. Section 10 found
   what a rename made from `references` rows has to collect by hand today,
   each said in a note of its own: the form lines that bind a handler or set
   a property (sub-properties and items included), other forms reaching a
   module's components through its Name, the class name in its methods'
   implementation headers, every link of a property's redeclaration chain,
   and the lines in branches the configuration does not compile, which no
   analysis resolves. The plan lists them as edits, the last as lines to
   check.
2. **`change_plan`** (done, 0.25.0, section 3) - for a routine, everything a
   signature change must touch, in one answer: the declaration and
   implementation, the overrides with theirs, the interface methods it
   implements and their other implementations, every call site with its
   enclosing routine. Before, `definition` + `related overrides` + `related
   implementations` + `callers` of each, the rows merged by the agent - and
   none of them found a descendant's hiding namesake tied by a bare
   `inherited;`. The family is the one a rename takes along (PasTree's
   `RenameFamily`, made public for it with the one-pass reference scan
   `CollectReferencesOfAll`): the ties dcc checks by name are the ties it
   checks by parameter list. Measured on the client group (four questions,
   `local/change-bench`): an interface method with one implementation, 382
   tokens in 0.3 s against 501 in four calls; a settings frame's change
   handler, 582 against 1,385 in four calls, its 29 form bindings said by
   file instead of listed; an overload, 478 against 385 in two; a base
   form's FormActivate, 5,067 tokens in 2.2 s for 140 signature lines in 70
   files - the 69 descendants' FormActivate hiding it and calling it by a
   bare `inherited;` - where `definition` and `callers` answered 102 tokens
   with one form binding and none of the 69.
3. **`implement_plan`** - for a class that descends from X and implements
   I, the abstract methods not yet overridden and the interface methods not
   yet implemented, as declarations ready to paste, with the unit each
   parameter type comes from.
4. **`scope_at`** - what a name would resolve to at a position, and what is
   visible there (`CompleteAt`): new code that binds correctly the first
   time instead of being found wrong by `compile`.
5. **`uses_for`** - for a symbol and a unit that wants it: the unit
   declaring it, whether it is already reachable, whether it belongs in the
   interface or the implementation `uses`, and whether adding it to the
   interface would close a circular reference.
6. **`defines`** (done, 0.27.0, section 3) - whether a line is compiled and
   what decides each `{$IF}`/`{$IFDEF}` around it, a file's lines not
   compiled, and where a conditional symbol is defined with every directive
   naming it. The `{$IFDEF}` branch an agent edits may not be the one that
   is compiled - and in a shared analysis, not the one another member of it
   compiles. Measured on the client group (`local/defines-bench`): a
   position 0.12-0.23 s and 215-540 tokens (two analyses reading the file
   answer apart where they differ), a file's uncompiled branches 39-592, a
   symbol's 21 directives 382 with its `$DEFINE` in the shared include named
   first. A line under the main program's own define is compiled as the
   analysis reads it and said not to be in two other builds: a COM server
   shares the analysis without that define, the server is analyzed apart
   without it. Before, grep for the directive, the `$DEFINE` in an
   include, each `.dproj`'s `DCC_Define` per configuration - and the
   members sharing an analysis were not told apart at all.
   Checked against dcc: on the client group a `{$MESSAGE WARN}` probe after
   each of 2,708 conditional directives in 201 files, every member built.
   Of 4,776 member-line pairs, 4,734 answers matched what dcc compiled, and
   the 26 where a member builds the line the other way
   (a COM server, a guardian, a browser host sharing the main program's
   analysis without its defines) carry the note naming the member. The one
   false text it found is fixed: a symbol only a member sharing the
   analysis defines was said to be defined by nothing in the group. 16
   pairs had no answer - the server's `.dpr` and `.dproj` name a unit `in`
   a file that does not exist and dcc takes the one on the search path;
   the index pinned the missing file and said F1027 in every importer.
   Fixed in 0.27.1 (PasTree 0.91.1 drops such a pin, the group reader no
   longer pins it or splits an analysis over it).

### 9.7 Checks and metrics

1. **`lint`** - named rules over the own units, each row tagged with its
   rule, capped like `diagnostics`; `rules` selects, `file` narrows.
   - `unused-uses` - a unit in `uses` none of whose names are used.
     Removing it takes a .dcu dcc loads for nothing out of every build of
     the importer, and an edge out of the `uses` graph and its cycles.
   - `uses-to-implementation` - an interface `uses` entry whose names are
     used only in the implementation. Moved, the unit can sit on a cycle
     (dcc refuses one through interfaces alone, F2047), and the interface
     says what it depends on. It does not change what recompiles: dcc 37
     recompiles a unit for a change to a symbol it binds, wherever the entry
     stands (probed 2026-10-04, see `metrics` below).
   - `unused-symbol` - a declaration with no reference in the group, except
     what is reached another way: published members, form bindings (so this
     rule waits for 9.5), `exports`, overrides, interface implementations.
     A false "unused" costs a deleted handler, so the exceptions are the
     rule.
   - `const-param` - a `string`, dynamic array, interface or large record
     parameter passed by value and never assigned in the body. The classic
     Delphi saving: no reference count or copy per call.
   - `create-without-finally` - a local object created and not released in
     a `try`/`finally` of the same routine (`FindCreations`,
     `FindDestructions`).
   - `empty-except`, `with-statement` - silent error swallowing, and the
     scope ambiguity that makes code bind differently after an unrelated
     change.

   The two `uses` rules need only the `uses` graph and references PasTree
   already has; the others need passes it does not have yet. Build the two
   first.

   The two are built (0.28.0) and checked against dcc on the client group -
   eight programs, 1,967 own units: 30,702 rows in about 2.5 s, 24,911
   unused-uses and 5,791 uses-to-implementation, 413 with a `but`.
   Removing every unused-uses entry without a `but` (24,687 in 1,785 files,
   by a script) left all eight building with the warnings they had, and none
   of the 20 units they stopped linking has initialization, finalization or
   a resource. Moving every uses-to-implementation entry without a `but`
   and outside a conditional block (5,560 in 1,420 files) - the same. The
   shared policy's rows are the strict policy's, with 7 `but`s more on the
   COM server analyzed with the main program's defines. The rounds before
   that found what section 3's row now describes, each a wrong row: a
   unit's form file naming its class, an alias bound through, a name of the
   interface bound to an implementation unit, the initialization a removal
   leaves out alone and together with the other rows, a program analyzed
   with another's defines, the overload dcc picks in another unit (two new
   W1057), an entry moved out of its `{$IF}` (F2613 in the program that does
   not define it) - and in PasTree 0.91.2, a parameter's type named like
   the parameter (`var X: X`) bound to the parameter, which said a unit
   used in the interface could move (E2003).

   With PasTree 0.93.4's rule asked (0.28.1): 13,988 unused-uses rows of
   the 24,911 - the rest were units an inline call needs or the designer
   puts back on save, mostly a form's ancestor units (Vcl.Controls,
   System.Classes). A whole-group run takes 18 s, almost all of it that
   rule; one file 1.5 s.

2. **`metrics`** - what the code costs the build, from the bindings and
   the `uses` graph PasTree already holds. `recompile` and `cycles` are
   built (0.29.0); per routine (lines, nesting, branches, callers) and per
   unit (lines, fan-in, fan-out) wait for a measured session to ask - today
   `source`, `outline` and `callers` answer them one at a time.

   **`recompile`** - what a change recompiles. Not by `uses`: dcc 37's Make
   recompiles a unit when a declaration it binds has changed. Probed with
   dcc64 37.0 on small programs (each unit compiled says so by a hint of its
   own):
   - a unit listing A in its interface and binding nothing of it is not
     recompiled when A's interface changes; nor is one binding only a
     declaration of A that did not change (another constant), nor anyone
     when A's `uses`, a body or a new routine nobody calls changes;
   - one binding A's constant, in its implementation as well, is;
   - a declaration changes with one it takes in, in its unit or another: a
     constant's value (`CM = CA + 1`), a field's type (a record holding A's
     record - and only its users, not the users of an unrelated constant
     beside it), a parameter's or a result's type (`procedure P(X: TCls)`
     when a private field is added to TCls), an ancestor, a pointer's target;
   - a member counts for its type: a unit calling only `GetObj.Method`
     recompiles when a field or a method is added to the class;
   - an overload set is one declaration: adding an overload recompiles the
     callers of another;
   - the body of an inline routine is part of it (its callers recompile when
     it changes), and so are the method bodies of a generic type - a unit
     only declaring a variable of `TGen<Integer>` recompiles when one
     changes.

   So the answer is a graph of the own units' interface declarations: who
   binds each, and which declarations take each in. A change to a
   declaration recompiles its binders and changes what takes it in, and so
   on; a unit's change is the same from all its declarations - the most a
   change there can recompile. With `symbol`: that cascade, per program, each
   unit with what it binds and the declarations of other units it spreads
   through; with `file`: the unit's, and its declarations ranked by reach;
   with neither: the own units ranked. The fixture's uRc* units mirror the
   probe, and dcc's Make recompiles exactly the smoke rows' units.

   Checked on the client group with the main program (Win32 Debug, 1,527
   own units compiled, each made to say so by a `{$MESSAGE}` of its own):
   five changes - a private field in a class bound by 16 units, a private
   field in a class carrying a form's declarations (88), a default
   parameter added to a routine (3), a string constant's value (111, most
   through an alias of it in another unit), a private field in the base
   class of the record layer (1,211) - recompiled every unit predicted, and
   two more in all: one per change of the last two, binding nothing the
   cascade reaches (dcc's own reasons, not found). A whole-group ranking
   takes 0.6 s; one cascade about as long.

   **One Make does not converge there.** dcc's Make on a program with large
   implementation cycles left units stale: after the constant's change it
   compiled 18 units, a second Make 22 more and a third 84, before one
   compiled nothing - and after the first, a unit using the constant still
   held its old value in its .dcu. The counts above are what the repeated
   Makes compiled, the changed unit included. What this means for `compile`
   (one Make) is a question of its own (9.4).

   **`cycles`** - the units on a `uses` cycle: dcc refuses one through
   interfaces alone (F2047), so each is closed by an implementation `uses`.
   Largest first, with the programs linking it, its entries, the shortest
   way round (through the unit asked, or the most connected), and the
   entries on it `lint` finds unused - removed, the cycle may break; the
   answer says the largest cycle left without those that have no `but`.
   Moving an interface entry to the implementation (`uses-to-implementation`)
   changes no edge of the graph, so it breaks nothing and is not offered
   here. A cycle of one analysis inside a larger one of another is that
   one seen with other defines: folded into it. On the client group: 34
   cycles, 971 units on them; the largest of 412 units, the next of 351 and
   231 in two configurations of the record layer - 15 s for the first five,
   nearly all of it PasTree's unused-uses rule, asked only of the files
   where the binding walk found an unused entry on a cycle.

### 9.8 Order

1. Enclosing routine on rows (done, 0.3.0), `source` (done, 0.4.0),
   `members` (done, 0.6.0) - cheap, every task uses them, and every library
   entry point they need is public.
2. `callers` (done, 0.5.0), `callees` (done, 0.7.0), `impact` (done,
   0.8.0).
3. `compile` (done, 0.9.0).
4. Forms (9.5) - done: `references` 0.10.0, `callers` 0.11.0, `impact`
   0.12.0, `form` 0.13.0, then corrected against the forms oracle of
   section 10 (0.15.0-0.16.7); `compile` puts a form file's link error on
   the `.dfm` (E2161, at the line the reader stops at) and a missing one on
   the unit's `{$R *.dfm}` (E1026) - 0.23.1.
5. The findings left open (10.4): enum values by name and F6.2 - both a
   false "nothing" - are fixed (0.17.0, 0.17.1), F6.4 and F6.3 too
   (0.19.0), the generic ancestor's E2003 (0.19.1) and `source` of
   overloads (0.20.0), F2084 (0.20.1) and F6.1 (0.20.2, PasTree 0.75.2) -
   none of 10.4's list is open. An audit on the client group (558 agents,
   599 calls of these tools against about 8,500 of grep and file reads)
   added three false answers, fixed in 0.22.0 (section 3's common rules):
   `*.Name` found nothing, `TDerived.Member` of an inherited member found
   nothing, and `references`/`callers` refused an overloaded name. What it left
   is done in 0.23.0: an F2084 that a Make over the first build's .dcu
   files does not get past (the named unit's .dcu deleted before the retry,
   and a retry known to fail not repeated), the exe `compile` builds said to
   be for checking, a project outside the group (its tests) indexed and
   built through `--also`, the uncompiled-branch note of `references` cut to
   the units that could name the symbol, `status` naming the server and its
   log, and a second server given the same `--log` logging beside it
   instead of not at all.
6. (Done 2026-10-01, 10.4: 12 tasks x 3 arms; it discriminates on
   overloads and a shadowed constant, and the tools arm skips the index
   unless told.) The task comparison of section 8, question 2, scaled up on tasks that
   discriminate (10.4), before any new tool: the pilot's tasks were solved
   by grep as well, so it has not yet said where the tools are enough and
   where an agent falls back - which is what this list should be ordered
   by.
7. Light mode (9.9; done, 0.31.0, on PasTree 0.117.1): library units read
   interface-only by default - the client group in 3.9 s / 1.5 GB instead
   of 6.9 s / 2.8 GB, every difference of the audit battery said in the
   answer. Since 0.32.0 (PasTree 0.121.0's workspace) the answers are the
   full analysis' - the library bodies a query needs made full inside it.
8. `rename_plan` (done, 0.24.0), `change_plan` (done, 0.25.0) - the notes section 10 added to
   `references` are the rename's parts, collected by hand today (9.6).
9. `mode: count | files` (9.2; done for `references`, 0.26.0) - the answers the limits cut are about widely
   used library members and properties set on thousands of form lines; a
   count per file first, then the lines of the files that matter.
10. `defines` (done, 0.27.0, 9.6; `{$IFOPT}` and the options at a line,
   0.30.0) - `references` names the lines in branches not
   compiled; `defines` says which define selects each, and for which member.
11. `lint` (the two `uses` rules - done, 0.28.0, 9.7), `metrics`
   (`recompile` and `cycles` - done, 0.29.0, 9.7). `unused-symbol`'s
   exceptions are measured: 24 of 384 sampled symbols that no code names
   are called through a base, an interface or a property, and a published
   property's uses are form lines.

12. Several targets per call (done, 0.43.0, 9.2) - asked for by the
   client group's sessions of October: half the reads of code around the
   tools wanted more than one routine at once.
13. A Claude Code plugin (not started): the server and the grep hook
   (8.2) installed in one step - a plugin carries an `.mcp.json` and a
   `hooks/hooks.json` together, from a marketplace that is a git
   repository. Today each is set up by hand, the hook in a settings file
   with the exe's path, and a colleague who registers the server but not
   the hook gets the 5-in-12 of 10.4. Open: where the plugin takes the exe
   from - a plugin is the files of a git repository, the exe is built
   locally (a release binary in the plugin, or the exe on `PATH`).
   After the hook is measured on our own repositories.

`type_of`, `overview`, `implement_plan`, `scope_at` and `uses_for` go in
when a measured session asks for them - the October audit (9.2.6) did not.

### 9.9 Light mode (0.31.0; complete answers 0.32.0)

The server used to analyze the whole `uses` closure completely, library
bodies included, though an agent asks about the project's own code and of
the RTL, the VCL and the third-party libraries needs the declarations. Since
0.31.0 the library units are read **interface-only** by default (PasTree's
light mode, 0.113.0-0.117.1: `TPasSemaProject.LightPaths`, PasTree
`docs/library-light-mode.md`), the own units as before. `--no-light` turns
it off; `--light <dir>` (repeats) adds a tree.

Measured on the client group (frozen copy, RAD Studio 37.0, medians of three
starts, `status`'s held memory):

| Policy | Mode | Units per analysis | Light | Load | Held |
| --- | --- | --- | --- | --- | --- |
| shared | full | 3,973 + 2,256 + 522 | - | 6.9 s | 2.8 GB |
| shared | light | 3,163 + 1,680 + 393 | 1,443 + 908 + 335 | 3.9 s | 1.5 GB |
| strict | full | 3,782 + 2,134 + 1,467 + 6 more (9) | - | 12.5 s | 4.6 GB |
| strict | light | 3,086 + 1,666 + 1,078 + 6 more (9) | 4,246 in all | 6.5 s | 2.2 GB |

Calls answered faster too in 0.31.0 (225 s against 328 s over 1,770 audit
calls), when light answers left library bodies out; since 0.32.0 an answer
that needs them pays for making them full, and the battery below takes a
little longer than in full mode (6.0 min against 4.9-5.4).

Every binding the analysis makes in the own units is the full analysis's
(PasTree's gate: 1,695 of 1,695 own units identical, by identity).

#### Which units are light

Per analysis: the installed library - the registry `Search Path` and
`Browsing Path` of its platform and the Studio source trees, the directories
the navigator calls library - and the `--light` trees, MINUS a library tree
under the group directory or an `--also` root, or holding either of them, or
holding a file a member lists. PasTree itself never reads light a listed
file (pinned), a root, or anything under the analysis' project directory.
So own code stays full, the in-repository copies of library units included:
the client group keeps its third-party sources outside the repository and
only its patched copies of some of their units (and of a few VCL ones) in
it, and those are own by section 4's rule. `status` names them as hints -
directories of own units no member lists a unit of, own units named as a
unit of a library directory - for whoever wants `--light <dir>` on them. A
`--light` tree under the group directory is library, not own (not watched,
not linted); one under a project directory stays own and full, which the log
says.

A light unit is its interface and its implementation `uses`; the units only
library implementations use are not loaded (`UNIT_NOT_LOADED`). Diagnostics,
the `status` count of unresolved names and the uses graph treat such an
entry as resolved and not loaded, not as missing.

#### Completeness inside the query (0.32.0)

Every answer in light mode is the full analysis' answer. Each analysis'
project and navigator belong to a PasTree `TPasWorkspace` (PasTree 0.120.0,
`docs/library-light-mode.md`, "The workspace"), and a tool asks through it
every question a library body can change: the query's demand - the light
units whose bodies or directives the answer needs - is met inside the
query (the units made full in one batch, the units only their
implementations use taken in), and then the question is answered over
them. The server holds no promotion loop and no list of what light mode
misses any more.

| Tool | Workspace entry |
| --- | --- |
| `references` | `FindReferences` (a symbol), `FindUnitReferences` (a unit, 0.32.1), `FindBuiltinReferences`, `FindDefineReferences` |
| `callers`, `impact` | `FindReferences`, `CollectReferencesOfAll` (a family's batch), `FindOverrides`, `FindDescendants`, `FindImplementations` |
| `related` | `FindDescendants`, `FindOverrides`, `FindImplementations`, `FindInterfaceImplementors`, `FindAssignments`, `FindCreations`, `FindDestructions` |
| `rename_plan`, `change_plan` | `PlanRename` (with the old name's uncompiled uses), `PlanUnitRename` (0.32.1), `RenameFamily`, `FindOverrides` |
| `callees` | `RoutineImplNode` (the routine's body), `EnsureDispatch` of every virtual or interface method the walk called, in one query per analysis once the walk is over (0.44.3; what may run: the class index then holds the library's implementation-only classes too) |
| `source`, `definition` | `RoutineImplNode` of each routine named |
| `lint`, `metrics cycles` | `FindUnusedUses` (PasTree's rule and its demand: inline bodies, initializations, and since PasTree 0.123.0 the units a library body keeps reached); the server's own reach asks `InFile` of each library unit whose initialization a removal leaves out, and walks past the loaded models as PasTree's rule does (0.32.2: `NotLoadedImports`, `NotLoadedUses`) - a lost unit a library body may still reach is not reported, the units nobody loaded on its way taken in, until the loaded graph answers |
| `references`' note on the name in uncompiled branches | the same walk: an own unit whose `uses` reach the declaring unit only through units nobody loaded has them taken in (0.32.2); an own unit under a light tree whose implementation spells the name, `InFile` |
| `defines` | `InFile` of the file asked about; `FindDefineReferences` of a name (the library's directives past a light unit's stop, through its preprocess-only completion) |
| `outline`, `unit_deps`, `diagnostics` of a library file | `InFile` (the unit made full - or taken in, when only library implementations use it) |
| `unit_deps` used by, `impact`'s "used by" | `FindUnitReferences` (0.32.1; in every light analysis, the unit loaded there or not) |
| a position (`file` + `line`) in a library unit | `At` |
| a target, in each analysis that did not produce it | `InFile` of its unit when that analysis has not loaded it or holds it light and the symbol is not there (0.32.1) |

The last row matters with several analyses: a library unit one analysis
loads through own code another may load only through library
implementations - not at all in light mode. Without its id there the
tools skipped that analysis, and with it the own calls it holds through a
virtual the target overrides: on the client group `callers` of
`TdxSubItems.Clear` lost 14 of 707 calls (through `TStrings.Clear`),
`impact` a member to build.

A query that changed the analysis - units made full, the project rebuilt
or escalated - leaves every model id, symbol index and model the tool held
stale: the tool runs again from the start (`EMcpIndexChanged`), and the
next run finds that demand met (an own question's demand is empty: own
code never pays). Once the runs of one call have taken 15 s, the next
query that needs any unit made full escalates instead (the bound set to
1 % of the library's volume for the rest of the call): every run repeats
the whole walk, and PasTree 0.122.0's narrower demands made `callees` of a
form's `FormActivate` at depth 2 run 10 times, 144 s, where a full rebuild
of the group's largest analysis takes 3 to 7 s. By time, not by runs
(0.32.1 counted four): a reference search over three analyses takes four
short runs, one per analysis made complete, and stays light. A search by
name (`QFind`) and the closure (`QClosure`) complete every analysis
before the tool runs again, one run for all (0.43.1): a `find` of a name
nothing declares ran four times on the client group, 13.2 s, now 9.5 s,
what remains the one-time taking in of light units (3.3 s for the exact
name, 2.6 s the closures, 2.1 s for `*name*`), 1.6 s warm; `--no-light`
answers it in 1.7 s after a 7.4 s load instead of 4. `callees` asks
the dispatch demands of its whole walk in one query once the walk is over
(PasTree's `EnsureDispatch`, 0.44.3): asked per virtual or interface call,
each query also ran the overrides' search the walk throws away (its own
class index answers) and restarted the walk - `callees` of the client
group's main form's `FormActivate` ran five times, 35 s, of which 7 s
made units full and escalated; now one run and the escalation, 10 s
(`--no-light`: 0.4 s after the load). What is left is the demand itself,
~50-70 ms a method in every call that has light units. A tool whose
queries keep changing the analysis runs at most 24 times; the last run
answers partially.

**Escalation** (PasTree's decision D8: run it). When the demand passes
`EscalationPercent` of the library's volume - `TObject`'s descendants, a hub
class's members, `Free`, a big unit's body on a small closure - a rebuild
without light paths is cheaper, and the workspace runs it: the analysis is
full from then on, for the session (D9), its members' later analyses
(rebuilds, a reload of the group) configure no light trees either. The
answer that caused it says so on its last line: "(the library was analyzed
in full for this answer; the analysis stays full)". The log has the
progress, `status` the count.

**NotSearched.** An answer is partial only when the client cancelled the
call (notifications/cancelled reaches the running query, the rebuild's
workers too) or PasTree refused a unit; its last line then says "(library
implementations not searched: N units)". A completed answer says nothing:
it is the full one.

**Searches by name (0.32.3, PasTree 0.124.0).** A declaration in a light
unit's implementation section, or in a unit only library implementations
use (833 units on the client group: `Winapi.ShLwApi`,
`Vcl.Shell.ShellCtrls`), is in no light model, and a search by name walks
the models' symbols - so 0.32.2's `find` missed them, a wildcard listed
fewer rows, its "N more" depended on what earlier calls had made full, and
a tool given such a name as `symbol` answered "no declaration named".
`find` (scope `all`) now asks `WS.EnsureFind` of every analysis first
(QFind): PasTree makes full the light units whose implementation DECLARES
a match - by its word index's declared names, so a unit that only calls
`Min` is left alone - and loads light the units nobody loaded that declare
one or whose unit name it is; a wildcard is matched against the
spellings of the scanned texts. Then the walk lists what the full analysis
lists. `scope: project` asks nothing (the own units are full). A member
inherited through the qualifier (`TFoo.Bar`) asks the qualifier only when
nothing matched, as the lookup itself does (InheritedMembers). Every other
tool given a `symbol` asks the same when nothing of that name is loaded
(ResolveName), so a name only an implementation declares resolves there
too; a name matching loaded declarations is resolved among them alone, as
before. A broad wildcard (`*Add*`, `*Create*`) is declared all over the
library's implementations, and the query escalates, as a hub class's
references do. Measured on the client group with the 400 `find` calls of
the 0.32.2 audit (200 exact names, 200 wildcards; the server restarted
after each escalated answer, so every call ran in a light session): **400
equal** to `--no-light` (0.32.2: 60 differed), the full answers
byte-identical to 0.32.2's; 17 calls escalated, every one a wildcard
(`*Add*`, `*Create*`, `*Min*`, `*Pos*`, `*Format*`, `*Clear*`,
`*TControl*` ...), none of the exact names.

An answer that counts the index ("no declaration matches X among the N
units indexed") or names the files outside it loads the rest of the
closure light first (QClosure, `WS.EnsureClosure`; no body made full):
the count and the outside-index note are the full analysis's, with no
light-mode remark. The include files light implementations read
(`NotLoadedFiles`) are not "outside the index" either.

What the answers still say in light mode, because no query completes it:

- `diagnostics` with `library: true` over the whole library: the light
  units report their interface only (`--no-light` checks every body; a
  library file asked about alone is made full first).
- `status`: per analysis, the units read interface-only and made full so
  far - or that it escalated - and what the queries paid ("queries completed
  in light mode: C of Q, R round(s), P unit(s) made full, L taken in, B
  rebuild(s), E escalation(s), T ms"), the refused units named.

#### Full vs light, measured

`tests\audit.ps1 -Against` (0.32.0): the battery over a sample run once
with `--no-light` (`-SampleOut`) and once in light mode over the same
symbols (`-Symbols`), every answer compared call for call.

- PasTree's own group (`PasTree.groupproj`, seed 1, 193 symbols - 36 of
  them library declarations): 1,290 calls, **1,290 equal, 0 differ**; two
  answers escalated (`definition` of `System.SysUtils.LowerCase` in one
  analysis and `references` of `System.Move` in the other, calls 1,048 and
  1,070), none partial. The battery took 0.3 min in light mode, 0.2 in full.
- The client group (frozen copy, seed 7, 232 symbols - 53 of them library
  declarations): 1,562 calls, **1,562 equal, 0 differ**, none partial. The
  first escalation came early: `callees` of an own routine at call 330,
  whose virtual calls into the VCL ask for every override below a hub class
  (the primary analysis full from there on); `references` of
  `FreeAndNil` escalated the other two at call 1,202. The same battery
  without `callees` (1,442 calls) escalated only at `FreeAndNil`, call
  1,117: **1,442 equal, 0 differ**, the first 1,116 answered in light mode -
  12 queries made units full on the way (1 to 140 units, 0.1-1 s each), then
  the three escalations (4.4, 2.7 and 1.1 s). The light runs took 6.0 min
  against 4.9-5.4 in full mode, the escalations included.

Those runs answered most calls in a session already escalated: after the
first escalation the analysis is full. 0.32.1 measured with the server
restarted after every escalated answer, so every call ran in a session
still light (the client group, seed 11, 200 symbols, `-Forms`,
`-Outlines 80`: 2,501 calls; and 1,558 more of the tools the battery does
not call - `rename_plan`, `change_plan`, depth 2, `metrics`, `defines`,
`unit_deps`, `diagnostics`, `lint`, wildcard `find`): 0.32.1 **2,498 and
1,494 equal**, 0.32.2 (PasTree 0.123.0) **2,499 and 1,500** - all that
differs is 60 `find` answers, equal since 0.32.3 ("Searches by name"
above). The full-mode answers
are byte-identical across 0.32.0-0.32.2. An escalation came every 30 to
100 calls (`callees` of an own routine calling a VCL virtual, `callers` of
a constructor, `references` of `Pos` or `Format`). The light lint costs
more where it takes units in: one file 16-20 s against 1.5 s full, the
whole group 71 s against 4.7 s, on a fresh session.

0.31.0 measured the gap the notes then described: 1,770 calls on the client
group, 282 differing - every one a light-mode note or a row lost in a
library body. 0.32.0 has none of those notes.

`tests\smoke.ps1` runs its main part in both modes (`references` of
`IntToStr` must be the same text in both), and `tests\fixtures\light` (a
library directory named with `--light`: an own override the library calls
from a body, an inline routine needing a unit, a registering
initialization, a unit only a library implementation uses) in both: every
answer equal but `status` and the whole library's `diagnostics`.

#### Still open

- One server shared by the sessions of a project (a socket or HTTP
  transport) - the other way to stop N sessions holding N indexes.
- `lint`'s own reach and the units only library implementations use (the
  note above): exact only through an escalation the server does not ask
  for.

#### 9.9.1 The PasTree side

Built in PasTree 0.113.0-0.117.1 (stages 1-5 and 9 of its light-mode plan):
light units parsed, preprocessed and lexed to the end of their
implementation `uses`, the exempt rules above, promotion (`PromoteUnit`,
`PromotedFiles`). Then 0.118.0-0.121.0: every query's demand, `EnsureFull`
(batch promotion, escalation), and `TPasWorkspace`, which runs them inside
the query; `PlanRename`'s uncompiled-uses overload through it (0.121.0).
Its `docs/library-light-mode.md` is the reference; this server's 0.31.0
needed 0.117.1, 0.32.0 needed 0.121.0, 0.32.3 needs 0.124.0 - the find
family: `EnsureFind`, `EnsureClosure`, `NotLoadedFiles`
(`cMinPasTreeVersion`).


## 10. What deep testing showed

The bench (README) sets an answer's tokens against grep; it does not say
whether the answer is right, or whether "none found" is true. In 0.13.0 an
ancestor's form binding a descendant's handler was found by chance, so a
round of testing looked for such defects on purpose: five phases on a copy
of the client group (9 members, about 4,000 units, 1.3M lines, 1,075 form
files), each against an oracle that is not PasTree, run on a frozen 0.13.0;
then one session fixing all they found - pastree-mcp 0.13.1 -> 0.16.7,
PasTree 0.65.0 -> 0.70.0, every fix with its smoke row or PasTree check -
and the phases rerun on the fixed server. The records name the client's
code and stay in `local/`; this section is what they concluded.

### 10.1 The oracles

| Phase | Oracle | Size |
| --- | --- | --- |
| 1 sweep | none: every answer checked for an error, a hang, its time and size, a header its rows contradict | 384 symbols drawn by `tests\audit.ps1` (a seed, stratified by kind and own/library), 3,967 calls, `form` of every form file |
| 2 grep | every word-boundary hit of the name in the sources and the text forms; a hit the answer lacks is classified by `definition` at it - the target (a miss), a namesake, nothing (unresolved) - and comments and strings by PasTree's tokens | 152 symbols, 101,115 hit lines, 5,811 `definition` checks |
| 3 compiler | the symbol marked `deprecated 'tag'`: dcc warns W1000 at every compile-time use in every unit and the build still succeeds - one build per batch of ten symbols, no rename-and-fix loop | 81 symbols in 8 batches, 3,536 sites, 56 builds |
| 4 forms | a text pass over every text form file giving, by TReader's rule and the ancestor-form rule, the lines that bind each published method | 5,702 handlers, 12,712 calls; the 5 binary forms by hand |
| 5 freshness | a cold server started on the same files after each edit step of a long-lived one; the answers must be equal with the freshness note stripped | 45 steps (a body, a signature, a method added and removed, a unit renamed, a new unit and form file, a `.dfm` edited, a file deleted, a `.dproj` changed), 290 answer pairs |
| 6 tasks (pilot) | answers settled beforehand by phases 3-4 and by `definition` at every grep hit; each task run by a fresh agent with the tools and one with grep and reads only, read-only, on 0.16.8 | 4 tasks x 2 arms, one run each, 8 agents |
| tools vs grep (0.44.0) | a tokenizer and structure walk of the source text, no name resolution: every declaration, routine body, member, `uses` entry and identifier; `compile` for lint (each `uses` entry removed, each interface one moved) and for diagnostics (one injected error per build) | this repository's self-index, 35 units, 118k lines; every tool in its modes, about 25,000 calls |

Each oracle found a class of defect the others could not: grep the form
lines that set a property, the compiler two overload rules, the text oracle
collapsed collection items, the cold server files the index took in and
never watched again. The fixture, written with the same understanding as
the code, reproduced none of them before they were found. Two things an
oracle needs that are easy to miss: a hint directive does not change a
unit's interface CRC, so an incremental build reports W1000 only in the
edited units - every batch deletes the own units' `.dcu` files first; and
dcc gives no W1000 at a method's implementation header, which the compiler
therefore cannot settle. `compile`'s answer equalled dcc's log in all 56
builds.

### 10.2 The numbers

| Criterion | Target | 0.13.0 | 0.16.7 |
| --- | --- | --- | --- |
| C1 false "nothing" | 0 | "0 references" for 24 of 384 routines called through a base, an interface or a property (1 to 1,334 calls each); a form file written after its unit: "no form file binds it" | such an answer says how many calls `callers` finds (the fixture's rows; the 24 not rerun one by one); the form file seen at the next call; text-visible 0 of 152 |
| C2 recall, code | >= 99% | compile-time 99.3% (3,497 of 3,521; 23 of the 24 misses overload resolution); text-visible 99.2% | overload misses 0; text-visible 99.12%, 100% with the 74 implementation headers the answer now counts |
| C2 recall, forms | - | handler lines 100% (6,777 of 6,777); form lines in phase 2's answers 34; `form` rows 99.92% | handler lines unchanged; form lines in phase 2's answers 5,066 (the lines that set a property, sub-properties and item properties included); `form` rows 20,687 of 20,688 - the one after a root's `end`, which dcc drops |
| C3 precision | >= 98% | 99.9% counting a link of the property's redeclaration chain (86.9% strict), the chain unsaid; `form`: 65 false "fails to load", 13 false "names no component" | 100% by the chain, the chain said; "fails to load" 0; "names no component" 3 - the product's own |
| C4 robustness | 0 | no crash, no hang in more than 20,000 calls over the phases | the same on the reruns |
| C5 latency p95 | < 1 s | every tool (worst `callers` 553 ms); 0.9% of calls over 1 s, up to 10.6 s | p95 < 1 s every tool (worst `callers` 511 ms); 0.3% over 1 s; the chain tail 8-10 s -> 1-2 s, and `related assignments` of a republished property 8.0 s -> 0.5 s (0.20.2) |
| C6 size p95 | < 5k tokens | every tool but `outline` (up to 141k in one answer) | `outline` and `form` bounded, 300 rows |
| C7 notes | every gap said | every cut said; not said: uses in branches not compiled, implementation headers left out, whose property a redeclaration answers for, what a cut left out | said |
| C8 freshness | identical | 266 of 290 pairs | 290 of 290 |
| C9 sufficiency | >= 80% of tasks, fewer tokens | - | pilot on 0.16.8 (10.4): 4 of 4 correct with the tools and 4 of 4 without; tokens with/without 1.04, time 0.71 - the tasks do not discriminate. Scaled up on 0.23.2 (10.4), 12 tasks x 3 arms, 1 run each: correct bare 9, tools 11, hint 10 of 12 (hint 2 partial); tokens tools/bare 0.97, hint/bare 0.87 |

The tools also found four latent defects of the product itself: three form
files naming components their forms do not have, and one with text after
its root's `end` - seven property lines dcc drops from the exe.

### 10.3 What the defects had in common

1. **Silence, not failure.** Nearly every high-severity finding was an
   answer wrong without a word: "0 references" read as dead code, "no form
   file binds it" after a form file appeared, a unit's edits unseen once the
   index had taken it in, the form lines of a property missing from its
   references. The fix was each time a row or a sentence, seldom a refusal:
   what an answer did not look at is part of the answer (9.1).
2. **A false alarm costs what a miss costs.** 65 "the form fails to load"
   for forms that load - a Boolean `OneOnRow` taken for an event, `OnX = nil`
   for a missing handler: an agent told a form fails to load "fixes" one
   that works. A rule read off a name (`On...`) is checked against the
   value's shape and, where known, the declared type.
3. **Forms are where the answers and the truth were furthest apart**, as
   9.5 expected: four of the nine high-severity findings. What they needed
   and the code did not was TReader taken literally - the class a
   sub-property is read in, a collection's item class from its default array
   property whatever its name, a class chosen at run time said rather than
   guessed.
4. **What a cut keeps matters as much as where it cuts.** Unbounded,
   `outline` gave 141k tokens; bounded by file order, `references` let 6,019
   form lines push the 25 redeclarations a rename changes out of a 5,000-row
   answer. A cut drops the least telling rows first - members before types,
   form lines before code - and says what it dropped.
5. **The slow tail is the library's.** Every call over 1 s was about a
   widely used VCL property or an own one redeclaring it - a scan per link of
   the redeclaration chain; own symbols stayed under 0.5 s at p95. One pass
   over the closure for the whole chain made it 1-2 s with the same rows -
   for `references`, `callers` and `impact`, and in 0.20.2 for `related
   assignments` (8.0 s -> 0.5 s), the last to scan per link.
6. **What the index takes in later is watched like what it loaded.** Both
   freshness defects (17 and 7 of the 24 unequal pairs) were files that came
   in after the first build: a unit a new `uses` pulled in, a form file
   written after its unit - an agent's order of work (section 5).
7. **A resolution rule not modelled is a miss and a wrong row at once.** An
   Integer argument for a parameter of a distinct `type Integer` and a
   one-character literal for a `Char` parameter sent 23 calls to a sibling
   overload - the only rows of any phase that were not uses of their symbol.
   The task pilot on the fixed server found a third (F6.2): an open-array
   constructor `['x']` bound to the overload whose parameter there is a
   string, and the overload it calls answered "none found" - a `[...]` now
   rejects what it cannot be passed to (PasTree 0.71.1, 0.17.1).
8. **An oracle that shares the tool's view shares its blind spot.** The
   phases drew their samples from `outline`, whose filter is the one name
   lookup uses, so no enum value was ever sampled - and none could be found
   by name. A colleague's session renaming two found it on a real task
   (0.17.0). `tests\audit.ps1` still samples from `outline`; the next
   sample should come from the source text too, not only from the index
   under test.
9. **A rule the host reads off the library's representation breaks when
   the library changes it, without an error.** The tools-vs-grep audit
   (0.44.0, oracle from the source text as item 8 asked) found every
   unscoped enum value hidden behind any namesake since PasTree 0.110.2:
   it joins one aggregate scope for a unit's enum values, and
   `IsScopedEnumValue` still looked for the enum's own - `find tkArray`
   answered System.TypInfo's constant, `source` and `references` resolved
   to it, for nine days. The same drift made `find` miss nested routines
   (0.44.0, `IsDeclSymbol`). The rest it found were edges of text the
   tools read themselves: a `class procedure` header, a generic type's
   method header, a header over 200 lines above its body, a generic's type
   argument taken for a creation (fixed in 0.44.1, each with a smoke row).
   Everything else agreed with the oracle: 4,157 of 4,163 reference sets,
   841 rename plans to the column, callees 6,369 of 6,371 and 18,830 of
   18,831 call lines, lint equal to 132 builds, diagnostics 80 of 80
   injected errors and none false.

### 10.4 Not measured, and the blind spots left

- **Sufficiency (C9) - a pilot only.** Four tasks, each with a trap for
  grep: the call sites of a routine and the projects to rebuild (two server
  members compile the unit too, one with no call in it); whether two
  handlers are dead (one
  whose name is on 76 lines of 48 files, one no code calls and only the
  ancestor's form file binds); a component rename next to a sibling form
  with the same name and the same code; who writes a value whose name
  belongs to 11 properties. Every run of both arms was right: the agent
  with grep read the declarations around each hit, knew the VCL's rule for
  an inherited form, and scripted the uses closure of nine `.dproj`. The
  tools saved where the grep route is long - the projects to rebuild, one
  `impact` call against a closure scan: 0.31x the tokens, a quarter of the
  time; elsewhere the agent with them spent the saving on checks it was not
  asked for (1.2-1.9x). Of its 11 fallbacks to grep or a read, 5 were
  cross-checks of a right answer, 2 a call by name through RTTI (no tool
  sees one), 2 the tools' gaps (F6.2, F6.3), 2 a tool it did not know
  answers. Every task named the declaring file or class, which shortens the
  grep route. The next tasks are ones where that route is long or misleads -
  overloads, virtual and interface dispatch, `with`, forms inherited several
  levels deep, project membership - asked also by a bare name; one run per
  task and arm says what discriminates, not a rate.
- **Sufficiency (C9) scaled up** (2026-10-01, pastree-mcp 0.23.2, 12 tasks
  x 3 arms, one run each, `local/audit/findings-phase6-scaled.md`). Arms:
  bare, tools (pastree configured, not mentioned), hint (tools plus the
  "use the index" lines). Correct / partial / wrong: bare 9/1/2, tools
  11/0/1, hint 10/2/0. Where grep misled: the overload of `Balance_asof`
  (bare found 5 of 10 calls) and a shadowed constant (bare named the
  other copy's readers); both pastree arms were right. The tools arm was
  wrong on `PosEQ` (said no call runs the string overload; Travel.PAS:500
  does) after a text search - it called pastree in 5 of 12 runs and not in
  that one; the hint arm called it in all 12 (62 calls). The hint arm's two
  partials were reasoning slips over a right index answer (a rename whose
  Reports frame it called optional; "fails to load" for a deleted handler).
  Cost, total tokens / seconds: bare 3.85 M / 647, tools 3.74 M / 472, hint
  3.35 M / 419; the project-membership task alone 931 k and 242 s bare,
  304-362 k and 30-45 s with `impact`. The three controls (dfAuto, handler
  rename across frames, field writers) were right on every arm at the same
  cost. One run per cell: this says which tasks discriminate and what the
  agents do, not a rate.
- **Found by the pilot** (on 0.16.8):
  - F6.1 (fixed in 0.20.2, PasTree 0.75.2): `related assignments` of a
    property an own class republishes scanned the closure once per link of
    the redeclaration chain - up to 8.1 s, where `references` of the same
    property takes 1 s; now one pass for the whole chain, as there. The 86
    `assignments` calls of the battery: every answer equal, the slowest
    8.0 s -> 0.49 s, all of them 35.9 s -> 12.6 s.
  - F6.2 (fixed in 0.17.1, PasTree 0.71.1): an open-array constructor
    argument was taken by an overload whose parameter is a string (10.3,
    7): the call listed under the wrong overload and the one it calls
    "none found" - a constructor that runs, read as unused.
  - F6.3 (fixed in 0.19.0): a `callers` row was the first line of a call
    written over several; the argument asked about - where a value comes
    from - was on the next, and the agent read the file for it. The row is
    now the call joined up to its closing parenthesis or bracket, comments
    dropped, at most 6 lines and 240 characters cut at an argument (the
    client group's such calls run to 190); a line that closes what it opens
    stays as it was. Over the 384-symbol battery: 82 answers of 2,592
    changed, all `callers` and `impact`, their size +2.0% and +1.4%.
  - F6.4 (fixed in 0.19.0): `form` of a class without a form file of its
    own refused; it shows the ancestor's form the class loads, each event
    bound on the class (9.5).
- **From a field report** (a colleague's session on a branch of the
  client group, mostly renames; `references` was its main gain): enum
  values by name (fixed, 0.17.0); `diagnostics` reporting E2003 on a member
  reached through a generic ancestor's type parameter, which dcc compiles
  (fixed, 0.19.1, PasTree 0.71.2: a routine of a generic ancestor called by
  its bare name - `GetRecord(0).Code` in a `class(TItemList<ICoded>)`
  descendant - was bound right and typed as the open `T`, as its call node
  had no instantiation frame; in a `with` body the member after it was left
  unbound with no diagnostic at all, a use `references` did not list. The
  shape was on their branch only; reproduced in the fixture, AppB\uGenLists);
  `source` of an
  overloaded name refusing where `definition` lists every overload, after
  which the agent read the file (fixed, 0.20.0: a name whose candidates are
  the overloads of one routine shows each, `limit` over them all; of 263
  names sampled on the client group 26 were refused, 9 of them overloads,
  now answered - the other 17 namesakes - and every other answer unchanged;
  for the reported method the refusal and one follow-up were two calls and
  430-630 tokens, all 7 overloads are one of 1,206, `part: decl` 337. Seen
  side by side, an external routine's second overload showed the first
  one's import line - SendMessage's INT_PTR one - now matched by its
  parameters);
  `compile` not saying that dcc's F2084 is
  the compiler's own failure and that a second build usually passes (fixed,
  0.20.1: such a build is run once more and the answer says which it was;
  not reproducible on demand, so the smoke test injects it through
  PASTREE_MCP_TEST_F2084).
- **A blind spot closed** (0.21.0, PasTree 0.76.0): `X[I]` over a default
  array property was a use no tool saw - the reference search follows
  names - and `callers` of its getter said so. PasTree now binds the
  brackets to the property; on the client group `callers` of TStrings.Get
  went from 149 calls to 1,267, of an own list's getter from 11 to 77, and
  `references` of TStrings.Strings from 312 to 2,566 (2,254 of them
  `[X[I]]`). Of the 2,592 battery answers 10 changed, each by the uses it
  had missed - `callees` of TStringGrid.GetCells was "none found" - and no
  tool got slower at p95. Found on the way (0.21.1, PasTree 0.76.1): a
  default property of several parameters took one index expression for
  all of them, so `S[C, R]` was typed one level deeper - to Char off a
  string, through the default property of its own type - and the member
  after it went unbound.
- **Said, not resolved**: late-bound OLE calls and `asm` (7 and 1 lines of
  phase 2's hits), calls through a method pointer, a form file with no unit beside it or one no project
  compiles, uses in a branch the analyzed configuration does not compile
  (named and counted).
- **The oracles' own blind zones**: dcc warns only in the units it
  recompiles and not at implementation headers; grep sees only what the text
  names, and the hits of common names past its cap (51,385 lines) were not
  checked one by one.

### 10.5 Repeating it

`tests\audit.ps1` is the tracked harness (README); the oracles of phases 2-5
are scripts over it, kept with their data in `local/` - their generic parts
still to move to `tests\`. A change to what `references`, `callers` or the
form binder answer reruns phases 2 and 4 on the copy, a change to section 5
reruns phase 5 - each under half an hour - against the numbers of 10.2.
