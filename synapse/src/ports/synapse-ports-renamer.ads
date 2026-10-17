--  Moving a note: its file name and every link to it, as one capability, so
--  the vault stays consistent and a note's title stays the same as its file
--  name. A separate capability from the store: not every store has links to
--  rewrite.

package Synapse.Ports.Renamer is

   type Renamer is limited interface;

   --  Both are full vault-relative paths. Raises Store.Node_Not_Found when
   --  Old_Path holds nothing.
   procedure Rename
     (R : in out Renamer; Old_Path, New_Path : String) is abstract;

end Synapse.Ports.Renamer;
