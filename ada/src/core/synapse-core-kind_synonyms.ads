with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  The kind-synonym rule list: the suffix of a `locals.scm` capture
--  (`@local.definition.<kind>`) mapped onto a tag's kind. The grammars
--  converge on one shared kind vocabulary in their tag queries, but the
--  locals queries were written for another consumer, so their spellings are
--  whatever the author picked.
--
--  An ordered list and not a keyed object, because the order is the
--  mechanism: rules are tried from the top, the first match wins, and a
--  spelling nothing matches is dropped. A rule may name one grammar's scope;
--  an unscoped rule matches any. That is what lets two grammars give one
--  spelling two meanings: the second grammar's rule sits ahead of the general
--  one. The list ships empty, and an absent or empty list is a supported
--  state.

package Synapse.Core.Kind_Synonyms is

   use Ada.Strings.Unbounded;

   --  One rule.
   type Rule is record
      --  The `@local.definition.<match>` suffix. Empty is a real spelling: a
      --  bare `@local.definition` with no suffix.
      Match     : Unbounded_String;
      Has_Scope : Boolean := False;
      Scope     : Unbounded_String;
      --  The kind the spelling means. Never empty.
      Kind      : Unbounded_String;
   end record;

   package Rule_Vectors is new Ada.Containers.Vectors (Positive, Rule);

   --  The rules of a configuration file, in file order.
   type Rule_List is record
      Rules : Rule_Vectors.Vector;
   end record;

   Malformed : exception;

   --  The list a JSON array of `{"match", "scope", "kind"}` objects describes.
   --  An entry that is not an object, or lacks a string `match`, or has no
   --  non-empty string `kind`, is left out: the rules around it still apply.
   --  An empty or non-string `scope` means any grammar. Anything but an array
   --  is an empty list. Raises Malformed when the text is not JSON.
   function Parse (Text : String) return Rule_List;

   --  Whether the list has no rule, which lets a caller skip a pass instead of
   --  walking every capture to learn it.
   function Is_Empty (List : Rule_List) return Boolean is
     (List.Rules.Is_Empty);

   type Maybe_Kind (Found : Boolean := False) is record
      case Found is
         when True =>
            Kind : Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  The kind of the first rule whose `match` is Spelling and whose scope is
   --  absent or is Grammar_Scope. None means unmapped: the caller drops the
   --  capture and does not guess.
   function Kind_For
     (List : Rule_List; Spelling, Grammar_Scope : String) return Maybe_Kind;

end Synapse.Core.Kind_Synonyms;
