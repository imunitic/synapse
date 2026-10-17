with Ada.Strings.Unbounded;

package body Synapse.Adapters.Fake_Repo_Reader is

   procedure Put (R : in out Reader; Path, Content : String) is
   begin
      R.Content.Include (Path, Content);
   end Put;

   function Reads (R : Reader) return Natural is (R.Count);

   overriding function Read
     (R : in out Reader; Path : String) return Ports.Repo_Reader.Maybe_Content
   is
      Place : constant Files.Cursor := R.Content.Find (Path);
   begin
      R.Count := R.Count + 1;
      if not Files.Has_Element (Place) then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value =>
           Ada.Strings.Unbounded.To_Unbounded_String (Files.Element (Place)));
   end Read;

end Synapse.Adapters.Fake_Repo_Reader;
