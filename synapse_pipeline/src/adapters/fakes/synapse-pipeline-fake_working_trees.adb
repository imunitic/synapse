package body Synapse.Pipeline.Fake_Working_Trees is

   use Ada.Strings.Unbounded;

   overriding
   function Snapshot
     (T : in out Fake_Working_Trees; Directory, Name : String)
      return Working_Trees.Maybe_Text
   is
   begin
      T.Directories.Append (To_Unbounded_String (Directory));
      T.Names.Append (To_Unbounded_String (Name));
      T.Taken := T.Taken + 1;
      if T.Taken > Natural (T.Snapshots.Length) then
         return Working_Trees.Maybe_Text'(Found => False);
      end if;
      return Working_Trees.Maybe_Text'
        (Found => True, Value => T.Snapshots.Element (T.Taken));
   end Snapshot;

   overriding
   function Changes
     (T : in out Fake_Working_Trees; Directory, Before, After : String)
      return Working_Trees.Maybe_Text
   is
      pragma Unreferenced (Directory);
   begin
      T.Compared.Append (To_Unbounded_String (Before & ".." & After));
      if not T.Patch_Known then
         return Working_Trees.Maybe_Text'(Found => False);
      end if;
      return Working_Trees.Maybe_Text'(Found => True, Value => T.Patch);
   end Changes;

   overriding
   function Pin
     (T : in out Fake_Working_Trees; Directory, Ref, Tree : String)
      return Boolean
   is
      pragma Unreferenced (Directory);
   begin
      if T.Pin_Fails then
         return False;
      end if;
      T.Pinned.Append (To_Unbounded_String (Ref & "=" & Tree));
      return True;
   end Pin;

   overriding
   procedure Unpin (T : in out Fake_Working_Trees; Directory, Ref : String) is
      pragma Unreferenced (Directory);
   begin
      T.Unpinned.Append (To_Unbounded_String (Ref));
   end Unpin;

end Synapse.Pipeline.Fake_Working_Trees;
