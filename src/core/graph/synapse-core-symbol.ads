with Ada.Strings.Unbounded;

with Synapse.Core.Tag_Payload;
with Synapse.Core.Text_Lists;

--  `query symbol <name> <node>`: is this symbol still in the node's sources?
--  Answered from the tags cache and never from a fresh parse, which cost the
--  number of sources times the size of the cache and could take minutes on a
--  large repository.
--
--  Three answers about a path: not cached, unsupported (no grammar, so that
--  filling the cache will not help) and checked. Only "checked, and the name
--  matched" is printed; "checked, not present" is silence, like every other
--  reporting subcommand. The other two are distinct diagnostics: conflating
--  "did not look" with "looked and it is gone" is how a caller comes to trust
--  an empty answer it should not.

package Synapse.Core.Symbol is

   type Outcome_Kind is (Not_Cached, Unsupported, Checked);

   type Outcome (Kind : Outcome_Kind := Not_Cached) is record
      case Kind is
         when Checked =>
            --  The encoded payload, for Matches to walk. Empty is real: a file
            --  with no tags was still checked.
            Tags : Ada.Strings.Unbounded.Unbounded_String;

         when Not_Cached | Unsupported =>
            null;
      end case;
   end record;

   --  What the cache knows about one requested path.
   function Outcome_For
     (Cached : Boolean; Unsupported : Boolean; Tags : String) return Outcome;

   --  The tags of a payload whose name is exactly Name, in the order they are
   --  stored: a definition and a reference are two answers. Exact and not by
   --  prefix: a prefix match would answer a `Token` query with every
   --  `Tokenizer` too. The tags themselves are returned, and what a match
   --  looks like on screen is the caller's decision.
   function Matches
     (Payload : String; Name : String) return Tag_Payload.Tag_Vectors.Vector;

   --  The paths of a list, in the node's own order and not the cache's, so
   --  that the report stays diffable against the node. Blank lines are
   --  skipped, and a carriage return ends no path.
   function Requested_Paths (Text : String) return Text_Lists.Vector;

end Synapse.Core.Symbol;
