with Ada.Strings.Unbounded;

with Synapse.Core.Grammar_Registry;
with Synapse.Core.Kind_Synonyms;
with Synapse.Core.Node_Types;
with Synapse.Core.Results;
with Synapse.Core.Tag_Payload;
with Synapse.Ports.Extractor;

--  Runs a grammar's query over a parse and turns the captures into tags.
--
--  A tag the query did not sanction is worse than no tag at all: it poisons
--  the tags cache and every answer built from it. So predicates are
--  evaluated and not ignored. The string comparisons (`#eq?`, `#not-eq?`,
--  `#any-of?`, `#not-any-of?`) are evaluated per match; `#match?`, which
--  needs a regular expression, and any predicate not recognised disable their
--  pattern, since assuming a filter passes costs a false tag and assuming it
--  fails only a missing one. Directives (a name ending in `!`) rewrite a
--  capture and do not filter, so they are skipped.
--
--  Three query conventions, by the Source a tagger is created with:
--  `tags.scm`, where `@name` marks the identifier and a sibling
--  `@definition.<kind>` or `@reference.<kind>` the role and kind;
--  `locals.scm`, where one `@local.definition.<kind>` capture is both, kinds
--  normalised through the kind synonym rules and an unmapped one dropped; and
--  a query written from the grammar's `node-types.json`, which is the
--  `tags.scm` shape plus a bounded walk for declarations that have no name
--  field. A person's own query file is read as `tags.scm`.
--
--  Independently of the source, a grammar's `locals.scm` can be given: a
--  reference whose name is bound by a local definition in the same file is
--  dropped, since it would otherwise be taken for an unresolved reference to
--  something in another file. The check is by file and not by scope, which is
--  coarser and errs only toward dropping a candidate that coincides with a
--  local name.

package Synapse.Adapters.Tree_Sitter.Tagger with
  SPARK_Mode => Off
is

   --  The tags of a file, as the tags cache holds them.
   package Tag_Vectors renames Core.Tag_Payload.Tag_Vectors;

   --  What a predicate name asks.
   type Predicate is
     (Directive, Equal, Not_Equal, Any_Of, Not_Any_Of, Unevaluable);

   function Classify (Name : String) return Predicate;

   type Create_Status is
     (Created, Query_Invalid,
      --  Every pattern of the query was disabled: it would match nothing, and
      --  that must not read as a file with no symbols.
      Predicate_Unsupported, Language_Rejected);

   type Tagger is limited private;

   function Is_Created (T : Tagger) return Boolean;

   --  Compiles Query_Text for Lang. Classification is the guesses a
   --  `Generated` tagger walks for; Locals_Text is the grammar's `locals.scm`
   --  when it has one. A `locals.scm` that does not compile, or whose every
   --  pattern is disabled, is left out and does not refuse the tagger.
   procedure Create
     (T              : in out Tagger; Lang : Language; Query_Text : String;
      Source         :        Core.Grammar_Registry.Query_Source;
      Rules          :        Core.Kind_Synonyms.Rule_List; Scope : String;
      Classification :        Core.Node_Types.Guess_Vectors.Vector;
      Locals_Text    :        Core.Grammar_Registry.Maybe_Text;
      Status         :    out Create_Status) with
     Pre => not Is_Created (T) and then not Is_Null (Lang);

   package Located_Vectors renames Synapse.Ports.Extractor.Located_Vectors;

   type Tag_Error is (Not_Created, Not_Parsed);

   package Tag_Results is new Synapse.Core.Results
     (Tag_Vectors.Vector, Tag_Error);

   --  The tags of one file, in the order the matches come. A file that parses
   --  to nothing has none, which is a success: it is not the same as one that
   --  could not be parsed.
   function Tag_File
     (T : in out Tagger; Source : String) return Tag_Results.Result;

   package Located_Results is new Synapse.Core.Results
     (Located_Vectors.Vector, Tag_Error);

   --  The same, each tag with the span of its name.
   function Tag_File_Located
     (T : in out Tagger; Source : String) return Located_Results.Result;

private

   type Tagger is limited record
      Ready      : Boolean                            := False;
      Main       : Query;
      Locals     : Query;
      Has_Locals : Boolean                            := False;
      Reader     : Parser;
      Source     : Core.Grammar_Registry.Query_Source :=
        Core.Grammar_Registry.Tags;
      Rules      : Core.Kind_Synonyms.Rule_List;
      Scope      : Ada.Strings.Unbounded.Unbounded_String;
      Guesses    : Core.Node_Types.Guess_Vectors.Vector;
   end record;

end Synapse.Adapters.Tree_Sitter.Tagger;
