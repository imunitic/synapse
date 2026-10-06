--  The strict YAML reader note schema documents are written in, and the merge
--  that applies an override document to a base schema.
--
--  It is not a general YAML reader. It accepts maps, lists, strings, decimal
--  integers, booleans, a literal `null`, flow lists of scalars (`[a, b]`) and
--  comments, with two-space indentation, and refuses what makes YAML
--  surprising: anchors and aliases, tags, block scalars, flow maps, more than
--  one document, tabs, implicit types such as `yes`, and duplicate keys.
--
--  A document reads as a JSON value: a map is an object (members in source
--  order), a list an array, `null` a JSON null. In an override a `null`
--  deletes the key it is attached to.

with Synapse.Core.JSON;

package Synapse.Core.Schema_YAML with SPARK_Mode => Off is

   package JSON renames Synapse.Core.JSON;

   --  Nesting limit of maps and lists.
   Max_Depth : constant := 128;

   type Fault is
     (Empty_Document,
      Tab_Indent,
      Invalid_Indent,
      Unexpected_Indent,
      Mixed_Collection,
      Malformed_Mapping,
      Duplicate_Key,
      Empty_Value,
      Anchor_Or_Alias,
      Custom_Tag,
      Block_Scalar,
      Flow_Map,
      Multiple_Documents,
      Implicit_Type,
      Unterminated_String,
      Invalid_Escape,
      Invalid_Integer,
      Invalid_Flow_List,
      Invalid_UTF8,
      Too_Deep,
      --  Merge faults
      Patch_Match_Not_Map,
      Patch_Match_Not_Found,
      Mixed_Patch_List,
      Patch_On_Non_List);

   subtype Parse_Fault is Fault range Empty_Document .. Too_Deep;

   subtype Merge_Fault is Fault range Patch_Match_Not_Map .. Patch_On_Non_List;

   type Parse_Result (Ok : Boolean := False) is record
      case Ok is
         when True =>
            Root : JSON.Value;

         when False =>
            Error : Parse_Fault;
            Line  : Natural;  --  1-based source line; 0 when none applies
      end case;
   end record;

   function Parse (Source : String) return Parse_Result
   with Pre => Source'Last < Positive'Last;

   type Merge_Result (Ok : Boolean := False) is record
      case Ok is
         when True =>
            Root : JSON.Value;

         when False =>
            Error : Merge_Fault;
      end case;
   end record;

   --  Override applied onto Base. Maps merge key by key at every depth: a key
   --  in both recurses, a key only in Base stays, a key only in Override is
   --  added, and a `null` in Override removes the key. Any other pair is
   --  replaced by Override's value.
   --
   --  A list in which some entry has a `match` key is a patch: every entry
   --  must be a map whose `match` is a map, and each applies in order to the
   --  list built so far. It merges the rest of the entry onto every Base entry
   --  that contains all of `match`'s fields, or removes those entries when the
   --  entry has nothing but `match`. A `match` that finds nothing is
   --  Patch_Match_Not_Found.
   function Merge (Base, Override : JSON.Value) return Merge_Result;

end Synapse.Core.Schema_YAML;
