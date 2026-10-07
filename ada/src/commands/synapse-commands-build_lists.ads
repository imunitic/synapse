with Ada.Strings.Unbounded;

--  `build-lists`: the manifest of nodes into one list of paths per node.
package Synapse.Commands.Build_Lists is

   --  `build-lists [--reenumerate]`: reads `manifest.tsv` of the work
   --  directory (`title<TAB>include<TAB>exclude`, the last two extended
   --  regular expressions), enumerates, writes `lists/NNN.txt` and
   --  `NNN.title` for each row, then `covered.txt`, `all-sorted.txt` and
   --  `unassigned.txt`, and prints a line per node and the coverage.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  The same, for the repository at Identity_Path.
   function Build
     (Env : Environment; Identity_Path : String; Reenumerate : Boolean)
      return Exit_Code;

   --  One row of the manifest. A row with no title or no include field is not
   --  one; a missing exclude field excludes nothing.
   type Maybe_Row (Found : Boolean := False) is record
      case Found is
         when True =>
            Title   : Ada.Strings.Unbounded.Unbounded_String;
            Include : Ada.Strings.Unbounded.Unbounded_String;
            Exclude : Ada.Strings.Unbounded.Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   function Parse_Row (Raw : String) return Maybe_Row;

end Synapse.Commands.Build_Lists;
