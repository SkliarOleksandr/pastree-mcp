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
  pick one; `kind` narrows (`class`, `function`, `property`...).
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
| `status` | project + model counts, `UsesList` health | Answers during loading too. Lists unit names that do not resolve: each one silences its importers' diagnostics, so it is the thing to know before trusting "no errors" or "no references". |
| `find` | symbol tables of every model, filtered as `ProjectOutline` | Exact, qualified or wildcard. No exact hit falls back to `*query*` and says so. Declaration sites are computed only for the rows shown - on the client group `Create` matches 25,000 symbols. `scope: project` = own units only. Nothing found says what was searched - `the 89 units indexed - what pastree-mcp.dproj compiles: 10 of its own, 79 from libraries` - and where the name is written outside the index: the index is the projects' `uses` closure, not the directory, and a unit no project uses is invisible to every tool. A session on PasTree, pointed at pastree-mcp's project, asked for its tree checker and its test kit and got a bare "no declaration matches", which cannot be told from "there is none". The Pascal sources no analysis holds - under the group directory at every level (`.git`, `__history`, `__recovery` skipped) and in the members' own search path directories, not the registry library path - are read as text, each segment of the name required in the file; per file the line that best says where it is, one that declares the dotted name or the last segment (a routine or `unit` keyword before it, or `=` / `:` after it) before one that only writes it, a declaration's parameter lines joined; a qualified name only scattered over a file leaves the file out. 5 files listed, the rest counted; 2 s at most, and the answer says when that cut the search short. The same note follows an exact miss's `*query*` rows, when it finds something, and every `symbol` a tool cannot resolve. On the client group 158 such files, 330 ms: an unused tool's `.dpr` found by its name. |
| `definition` | `DeclHit`, `GotoImplementation` | For a routine also the implementation (its header line, found by scanning up from the body start `GotoImplementation` returns). `context: N` appends N source lines - of the implementation when there is one. Several matches are all listed; this is the one tool where a list is the answer. |
| `source` | `DeclRootOf`, `GotoImplementation`, the raw token stream | The exact text of one declaration: a routine's implementation (`part: impl`, the default when it has one), its declaration (`decl`) or both; a type's whole declaration; a constant with its value. The node's span gives both ends - no line count to guess, as `definition context` makes the agent do. A name whose candidates are all overloads of one routine - one type's method, one unit's routine - shows each, headed by its declaration line, `limit` counted over them all and the ones past it named: refused, an agent read the file instead of making the second call (FR.3). Namesakes in different types are refused with the candidates, as elsewhere. The comment directly above comes with it, read from the comment tokens the lexer keeps: comments starting their own line, no blank line between them and the declaration; one longer than 30 lines is named, not shown (in old code it is as often a commented-out earlier version as documentation). Lines come from the model's token stream, so they are numbered like every other answer. `limit` caps each part (300 lines). A routine with no body says why: abstract, an interface method, external. |
| `members` | `EnumMembersX`, `DeclTypeX`/`SymDeclTypeX`, `XParamSyms`, `IsBarePropertyRedecl` | Every member of a class, record or interface, the inherited ones included: an outline per ancestor - once the ancestors are found - in one call. Rows are grouped by the type declaring them, the type asked about first and then each ancestor as `FindMemberX` climbs, under the visibility section they are written in (`published` for the unnamed first section of a `TPersistent` descendant), one declaration line each; the header is the ancestry, `TDerived <- TBase <- TObject`. The first member of a name met is the one a call binds to, so a later one is what an override or a redeclaration replaces, and is left out - unless every routine of the name met so far says `overload` or `override` (an override replaces one slot: `TStrings.AddStrings(TArray<string>)` is still called on a `TStringList`) and its parameter types are its own. A bare `property Items;` says nothing of its type: `[type TStrings]`. Whose reach: by default the type's own methods - all of its own members, of an ancestor's what Delphi lets them reach (`private` only in the same unit, `strict private` never); for a library type, what any code can use, since no method of it is the agent's to write; a variable, field, property or parameter (an inline `var X := ...` included) lists the members of its type that code in its unit can use. `visibility` public, protected (a descendant in another unit) or all; what it leaves out is counted. A library ancestor of a group type is counted per type, not listed (`library: true` lists it), unless `match` looks for a name: a form's run to `TObject` is 640 members the agent knows. `member_kind` and `match` narrow - `kind` already narrows the target, and one parameter read two ways is one more thing the model gets wrong. `limit` (150) caps the rows; the rest is counted per type. No class helper: one is in effect where it is in scope, and a type asked about has no such place. |
| `references` | `FindReferences`, `FindUnitReferences`, `FindBuiltinReferences`, `FindDefineReferences` | Rows in compiled units read from a `.dcu` (no source) are counted, not shown. A default array property says that `X[I]` uses it without its name, and that those uses are not in the list (PasTree's search follows names). A routine no code names by name, reached through the virtual method it overrides, an interface method it implements or a property it is the accessor of, says so with the count `callers` finds - "0 references" alone was read as dead code (24 of 384 sampled symbols on the client group: 1 to 1,334 calls each). A published property's form lines - `Caption = ...` set on an object whose class has it, a bare `property X;` taken for the property it republishes - are rows under their component (PasTree 0.68.0): TReader sets it by name, so renaming or removing it fails when the form loads after a clean compile; one no form sets says "no form file sets it". A sub-property (`Font.Name`) is looked up in the class of the property before it, an item's property in the item class of its collection - the type of the collection's `default` array property, whatever its name (`TActionClients.ActionClients`), else `Items` (PasTree 0.70.0); a sibling `<Prop>ClassName` string line (`PropertiesClassName`, the DevExpress editors' convention) names the class read. Where the class read is a declared type without the property - a descendant item class, a property object whose class is chosen at run time (`CommandProperties.Font` of an action item: TTextProperties or TMenuProperties by its `CommandStyle`) - the line is a row tagged `[may be another class's]` and said once: left out, it is a silent miss (18 `CommandProperties.Font.Name` lines on the client group). An answer the limit cuts lists its code rows first and counts the form lines it left out - form lines filling the rows by file name hid the code a rename changes (25 `property TabOrder;` redeclarations behind 5,000 `TabOrder = N` lines). The name written in a conditional branch the analyzed configuration does not compile is not a row - nothing there is resolved - but the lines are named (the first five) and counted: an edit made from the rows misses them, and the build that selects the branch breaks; `definition` at such a line says the branch is not compiled. |
| `callers` | `FindReferences` per source, `MethodAt`+`FindOverrides`, `FindDescendants`, `FindMemberX`, `GotoBareInherited`, `XDescendsFrom`, `WithTargetTypeX` | `references` folded to the routines the calls sit in, and what a reference search cannot see. A call is written against a *source*: the routine; a virtual method it overrides (the chain climbed from its class, stopping at the root or a `reintroduce`); an interface method it implements - a same-named method of an interface that its class, an ancestor or a descendant lists, or that one extends, when the member that name finds from the listing class is the routine or a method it overrides (`FindImplementations` is not asked: it answers only for the interface a class lists itself); a property it is the getter (reads) or setter (writes) of. Through a virtual slot a row counts only when the receiver's static type may hold an object that runs this implementation (`LSquare.Area` bound to `TShape.Area` never runs `TCircle.Area`; a property read on a class that overrides the getter runs the override), and `inherited X` never dispatches. A bare `inherited;` names nothing: the overrides below the class - for a constructor that is not virtual, the same-named constructors of its descendants - are scanned for one, and `GotoBareInherited` says what it calls. Each reference is classified from the tree: a call, or the routine handed on - `@Foo`, `OnClick := Foo`, a procedure passed as an argument - tagged `[not a call]` and not followed. A function named without parentheses is a call unless assigned to something procedural; as an argument it is taken for a call. `depth` 1-4 follows the routines the calls sit in, own files only (a library routine is shown, not followed), each site once; `limit` (150) caps the rows over all levels, and a level past it is not searched - the answer says so (a getter read 379 times, depth 3 and no cap: 34 s, 81k tokens). Tags: `via X` for a row bound to another source - dropped from the rows and said once above them when every first-level row shares it; `-> X` on a deeper row, the routine of the level above it reaches; overloads of one name told apart by declaration line. A routine searched and found uncalled is named at the end, and a published one (or in the unnamed first section of a `TPersistent` descendant) gets the note that a `.dfm` may bind it (9.5). A destructor points to `related destructions`. |
| `callees` | the body's `RefMap`/`ExtRefMap`, `RefUse`, `PropertyRedeclPrev`, `GotoBareInherited`, `FindMemberX` over a class index (`AncestorOfX`, `ListedInterfaces`) built once per call | What a routine calls - `callers` from the other end. The body is walked from the tree - its block, its local declarations and anonymous methods, not its nested routines, which are callees of their own - and each name is taken for what it binds to: the overload the compiler chose (PasTree writes it into the maps), a property's getter or setter for a read or a write (a republished `property X;` takes its ancestor's), what a bare `inherited;` runs; a routine handed on (`OnClick := Foo`, `@Foo`) is `[not a call]`, classified as in `callers`. One row per routine reached, at its declaration line, grouped by file under its type, with the lines of its calls: `[at 19, 31]`. A virtual call made on an object - not on a type name, not `inherited X` - adds what that object may run: for its static class and every class below, the method the slot finds there, its own or the nearest ancestor's - so an override between the method's class and the object's is found (a property's accessor binds where the property is declared), not only those below. An interface call: the same over every class taking the interface on, listing it or one extending it. `[via X]` names what the call is written against. More than 10 such methods, merged over the analyses, are counted, not listed: a base class's hook called on Self has a dozen or two in a real group. Calls through a method pointer or a procedural variable are named - what they run is assigned at run time - and built-ins listed once. `depth` 1-4 follows the routines reached, own files and with a body, each once; a row below the first level names its caller, `[TFoo.Load at 40]`; `limit` (150) caps the rows over all levels. Not seen: a record's operators and implicit conversions, a for-in's enumerator, `X[I]` over a default array property, a method resolution clause (`procedure IFoo.Bar = Baz`). |
| `impact` | the walk of `callers` over several roots, `FindReferences`, `FindUnitReferences`, `FindImplementations`, each model's `UsesList`, the model `Diags` | What a change reaches, in one answer: `callers`, `related overrides` and `unit_deps` at once, and the question none of them answers - which members of the group to build and test. Given a unified diff (`git diff` output the agent passes as text - the server runs no git) or declarations (`symbol`, `symbols`, file + line + name). A diff's paths resolve against the group directory or a directory above it: git writes them from the repository root, which may hold more than the group. Its `+` and context lines must read as the file on disk does - compared with every character past ASCII dropped, since a diff that went through a console may carry those in another encoding - or the file is refused by name: a diff of another state numbers another file. A changed line of code touches the innermost declaration around its tokens: a routine as a whole (a nested routine, an anonymous method, a local are its routine's), a type, a variable, constant or property of a unit or a type; of those met on one line, one holding another is left out (the `;` after `property X ... read FX` is the class's token). A line with no token of its own (a directive) is the point between the tokens around it. A run of removed lines beside added code is read from the added lines alone - its removal point, between two members, would name the class - and a run that only removes is that point; out of a type, the members it removes are named rather than the type. Outside every declaration, the place: a uses clause, initialization, finalization, a main block, exports. Comment-only lines touch nothing (read from the diff's text, so removed lines too). A type every line of which is added is new: listed alone, its members and their implementations folded into it. A removed routine, property or type - declared on a removed line and on no added one, so a changed signature is not a removal - or a field removed from a type is named with the own-unit diagnostics still quoting its name: the calls a rename or a deletion left behind. **Members to build and test**: those whose closure holds a changed unit (a form's unit, an include's includers, a `.dproj`'s own member) - a member's closure is what its main source reaches through `uses`, read per member in its own analysis, since an analysis holds several (section 4); a file compiled into fewer members than the list is tagged with them. A unit whose interface section changed says how many units use it, their names up to 8 (the dependents' own recompile, and where to run `diagnostics`). Each declaration says the method it overrides (the chain's nearest link - what a changed signature must still match), the interface methods and properties it is also called through, its overrides and, for an interface method, its implementations - 10 each, then counted. Then the walk of `callers` from all of them at once: a declaration that is no routine is searched for its uses, a field also through the property that reads or writes it; with several roots a row names the one it reaches (`-> X`). 40 roots are searched (the walk is the time: about 125 ms a root on the client group), 100 declarations listed, `limit` (150) rows. `depth` as in `callers`. |
| `compile` | none: MSBuild (a `.dproj`) or dcc (a bare `.dpr`/`.dpk`) as a process of its own; `impact`'s member closures for which members; the tree for the routine of a row | The members a change reaches, built by the real compiler: those named (`member`), those compiling `file`, else those the files changed this session reach (what the freshness check of section 5 found). MSBuild over the member's `.dproj` with its platform and configuration, target `Make` - `Build` also runs AutoIncBuildNumber, which rewrites the `.dproj` of a project that increments its build number; a bare `.dpr`/`.dpk`, dcc directly with the member's paths and the registry search path. Every output - exe, dcu, bpl, dcp, hpp, obj, resources, type library - goes to the member's build directory (`--build-dir`, default `%TEMP%\pastree-mcp\<group>-<hash>\<member>-<platform>-<config>`), and pre- and post-build events are not run: the answer names them. The first build seeds the dcu directory with the developer's own `.dcu` files, from where MSBuild evaluates `DCC_DcuOutput` to (a probe: a target that does nothing, at diagnostic verbosity), so dcc recompiles what changed since, as the IDE's Compile would. The environment is rsvars.bat's plus the IDE's own variables, which the library path names. The answer: per member, built or FAILED, the time, dcc's line count and the exe; the errors, own files first, each under its file with the routine it sits in and the source line below; an F2063 (could not compile used unit) folded under the unit whose errors caused it; build errors that are not the code's (MSBuild's own, a resource or type library tool); the search path directories that do not exist when a unit was not found; then the warnings and hints of the group's own files that are new since the member's previous compile, the rest counted. New is per unit, since `Make` reports a unit's warnings only when it recompiles it: a unit recompiled has its stored warnings replaced, one not recompiled keeps them, and a unit never compiled here before counts as new only in a file changed this session. `show: warnings` lists every warning of the group's files, `all` every hint too; library units are counted only. dcc cuts a message's `file(line)` at 128 characters, and MSBuild then does not see it as an error at all: the file is found by the prefix, the line by the name the message quotes when exactly one line writes it. A build that stops at dcc's own internal error - an F2084, no error of the code beside it - is run once more, a Make over the .dcu files the first one wrote: the compiler failing, not the code, and the second usually passes; the answer is the second build's, the first one's error said on the member's line, and one that comes back twice says so and points to `rebuild: true` (FR.4: a colleague's build failed once with F2084 in a unit the change did not touch, and passed on the second). Progress notifications while it runs, when the call carries a token; the other calls are answered while it builds, and a cancelled call kills the build (section 7). `limit` (60) caps the rows. |
| `related` | `TypeAt`+`FindDescendants`, `MethodAt`+`FindOverrides`, `InterfaceMethodAt`+`FindImplementations` / `InterfaceAt`+`FindInterfaceImplementors`, `AssignableAt`+`FindAssignments`, `ClassAt`+`FindCreations`/`FindDestructions` | The `...At` test runs at the declaration site - it normalizes (method to its declaration, alias to its type) and refuses what the relation cannot mean, which becomes an error naming what was needed. Rows are grouped by file like every answer; a descendant names its parent (`<- TParent`) below the first level, and a tagged row whose source line repeats the previous row's (an override chain is one signature) shows only its tag. An indented tree was tried first: it repeats a path per row and cost as much as grep on a 250-class hierarchy. |
| `outline` | `PasModuleOutline` | Sections, uses, includes, types with members, routines with signatures, each with its line. `owner` and `section` filter; `members: false` keeps only types and bodies. A routine's or property's parameter list and result are rebuilt from the tree, whole: PasTree's `Detail` is an editor's hint cut at 80 characters, and a cut mid-name followed by the result type - `AInterfa...: TPasTree` - reads as one more parameter. The same text and the same 160-character cut at a parameter boundary as a declaration row; on the client group a 22,000-line form's outline grew 1.2%. `limit` (300 rows) bounds it: over it, the types' members are left out first and the answer says how many (`owner` gives one type's back), then the rows are cut and counted - the client group's largest shared unit was 11,202 rows, about 141k tokens, in one answer, and 400 rows of it without members still 7k. |
| `diagnostics` | model `Diags` | Own units by default. Each unit reports from ONE analysis - its owner (section 4) - so a unit analyzed under two configurations does not report twice. Over the limit, a per-file count comes first. |
| `unit_deps` | `UsesList`, `NodeSite`, `FindUnitReferences` | Uses resolved to files, implementation-section ones marked; used-by merged across analyses. |

What comes next - new tools and changes to these - is section 9.

## 4. Project groups

A `.groupproj` lists `.dproj` (or bare `.dpr`) members. The client group has
nine, 7,700 units in all; pastree-lsp's one-process-per-project shape costs
3.5-4 GB per member there, which does not fit.

**An analysis** (`TMcpAnalysis`) is one `TPasSemaProject` whose roots are the
main sources of one or more members. `TPasSemaProject` caches units by full
path, so members in one analysis parse their shared closure once.

**Which members share an analysis** is the group policy:

- `shared` (default): one analysis per platform. Its defines, and the last
  word on aliases, come from the member that creates it - members are placed
  LARGEST FIRST (most listed files). That order is load-bearing: in file order
  a one-file helper project created the Win64 analysis, the server project ran
  under the helper's defines, took client-only `{$IFDEF}` branches, and
  reported 170 unresolved units and 8,000 errors its own build does not have.
  Every member whose defines differ from its analysis' is logged.
- `strict`: one analysis per distinct (platform, defines, namespaces,
  aliases). Exact.
- Under both, a member listing a DIFFERENT file for a unit name already pinned
  in an analysis gets a new one: an analysis can hold one `Foo.pas`.

Measured on the client group (RAD Studio 13.0, 32 GB machine):

| Policy | Analyses | Units | Load | Held |
| --- | --- | --- | --- | --- |
| shared | 3 | 3958 + 2248 + 522 | 9.3 s | 2.7 GB |
| strict | 8 | 3767 + 2126 + 1464 + ... | 15.9 s | 4.3 GB |

Search paths of an analysis: every member's directory, every member's
`DCC_UnitSearchPath`, then the installed library (registry `Search Path` and
`Browsing Path` of that platform, macros expanded, then the Studio source
trees). Every member's listed `.pas` files are pinned (`PinUnitFile`).

**Owner analysis.** Each own file has one: the analysis that lists it (lowest
index first, analysis 0 holding the largest member), else the first that
reached it. Diagnostics come from the owner only.

**Own vs library.** A file under the group directory, or listed by a member,
is own. Everything else is library: not watched, demoted after every build,
listed after own files.

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

After every build `DemoteText` frees the text layer of every library unit and
keeps own units warm. Library positions and snippets come back through
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
   open.
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
6. **Several targets per call.** `definition`, `source` and `references`
   take `symbols: [...]` beside `symbol`. Understanding a change usually
   means three to six symbols; each turn re-sends the whole context, so the
   saving is in turns, not in answer tokens.
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
   a `.dfm` binds (9.5), `X[I]` over a default array property (PasTree's
   reference search follows names), a call through a method pointer (the
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

- **Output goes to a temporary directory** (`DCC_ExeOutput`, `DCC_DcuOutput`
  overridden), never to the project's own output: an agent's check must not
  replace the binary a developer is running, nor leave `.dcu` files from
  another compiler version where the IDE will find them - they are not
  portable between compilers (CLAUDE.md).
- **The compiler is the truth.** PasTree's diagnostics are a fast
  approximation and can differ. `compile` exists so the agent trusts neither
  blindly: `diagnostics` while editing, `compile` before saying done.
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
  directive and no file is itself worth reporting.
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

### 9.6 Refactoring and new code

1. **`rename_plan`** - `PlanRename` / `PlanUnitRename` as a list of edits
   (file, line, column, old, new) the agent applies itself. Section 10 found
   what a rename made from `references` rows has to collect by hand today,
   each said in a note of its own: the form lines that bind a handler or set
   a property (sub-properties and items included), other forms reaching a
   module's components through its Name, the class name in its methods'
   implementation headers, every link of a property's redeclaration chain,
   and the lines in branches the configuration does not compile, which no
   analysis resolves. The plan lists them as edits, the last as lines to
   check.
2. **`change_plan`** - for a routine, everything a signature change must
   touch, in one answer: the declaration and implementation, the overrides
   with theirs, the interface methods it implements and their other
   implementations, every call site with its enclosing routine. Today that
   is `definition` + `related overrides` + `related implementations` +
   `references`, four or five calls whose rows the agent merges itself.
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
6. **`defines`** - where a conditional symbol is defined and which are in
   effect at a position (`FindDefines`, `DefinesAt`). The `{$IFDEF}` branch
   an agent edits may not be the one that is compiled.

### 9.7 Checks and metrics

1. **`lint`** - named rules over the own units, each row tagged with its
   rule, capped like `diagnostics`; `rules` selects, `file` narrows.
   - `unused-uses` - a unit in `uses` none of whose names are used.
     Removing it shortens every build that compiles the importer.
   - `uses-to-implementation` - an interface `uses` entry whose names are
     used only in the implementation. Moving it cuts the recompile cascade
     when that unit's interface changes, and breaks cycles.
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
2. **`metrics`** - per routine: lines, nesting depth, branches, callers;
   per unit: lines, fan-in, fan-out, and how many units a change to its
   interface recompiles; and the `uses` cycles through interface sections.
   Where to look first when optimizing a build or a hot path, from the AST
   and the `uses` graph PasTree already holds.

### 9.8 Order

1. Enclosing routine on rows (done, 0.3.0), `source` (done, 0.4.0),
   `members` (done, 0.6.0) - cheap, every task uses them, and every library
   entry point they need is public.
2. `callers` (done, 0.5.0), `callees` (done, 0.7.0), `impact` (done,
   0.8.0).
3. `compile` (done, 0.9.0).
4. Forms (9.5) - done: `references` 0.10.0, `callers` 0.11.0, `impact`
   0.12.0, `form` 0.13.0, then corrected against the forms oracle of
   section 10 (0.15.0-0.16.7). Left: a form file's link error (E2161)
   attached to the `.dfm` in `compile`'s answer.
5. The findings left open (10.4): enum values by name and F6.2 - both a
   false "nothing" - are fixed (0.17.0, 0.17.1), F6.4 and F6.3 too
   (0.19.0), the generic ancestor's E2003 (0.19.1) and `source` of
   overloads (0.20.0), F2084 (0.20.1); then F6.1.
6. The task comparison of section 8, question 2, scaled up on tasks that
   discriminate (10.4), before any new tool: the pilot's tasks were solved
   by grep as well, so it has not yet said where the tools are enough and
   where an agent falls back - which is what this list should be ordered
   by.
7. `rename_plan`, `change_plan` - the notes section 10 added to
   `references` are the rename's parts, collected by hand today (9.6).
8. `mode: count | files` (9.2) - the answers the limits cut are about widely
   used library members and properties set on thousands of form lines; a
   count per file first, then the lines of the files that matter.
9. `defines` (9.6) - `references` now names the lines in branches not
   compiled; which define selects each is the next question.
10. `lint` (the two `uses` rules first), `metrics`. `unused-symbol`'s
   exceptions are measured: 24 of 384 sampled symbols that no code names
   are called through a base, an interface or a property, and a published
   property's uses are form lines.

`type_of`, several targets per call, `overview`, `implement_plan`,
`scope_at` and `uses_for` go in when a measured session asks for them.

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
| C5 latency p95 | < 1 s | every tool (worst `callers` 553 ms); 0.9% of calls over 1 s, up to 10.6 s | p95 < 1 s every tool (worst `callers` 511 ms); 0.3% over 1 s; the chain tail 8-10 s -> 1-2 s, but `related assignments` of a republished property still up to 8.1 s |
| C6 size p95 | < 5k tokens | every tool but `outline` (up to 141k in one answer) | `outline` and `form` bounded, 300 rows |
| C7 notes | every gap said | every cut said; not said: uses in branches not compiled, implementation headers left out, whose property a redeclaration answers for, what a cut left out | said |
| C8 freshness | identical | 266 of 290 pairs | 290 of 290 |
| C9 sufficiency | >= 80% of tasks, fewer tokens | - | pilot on 0.16.8 (10.4): 4 of 4 correct with the tools and 4 of 4 without; tokens with/without 1.04, time 0.71 - the tasks do not discriminate |

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
   for `references`, `callers` and `impact`; `related assignments` still
   scans per link (up to 8.1 s).
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
- **Open after the pilot** (found on 0.16.8, not fixed yet):
  - F6.1: `related assignments` of a property an own class republishes
    scans the redeclaration chain per link - up to 8.1 s, where
    `references` of the same property takes 1 s.
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
- **Open from a field report** (a colleague's session on a branch of the
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
- **Said, not resolved**: late-bound OLE calls and `asm` (7 and 1 lines of
  phase 2's hits), `X[I]` over a default array property, calls through a
  method pointer, a form file with no unit beside it or one no project
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
