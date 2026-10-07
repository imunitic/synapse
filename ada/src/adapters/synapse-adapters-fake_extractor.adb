with Ada.Strings.Unbounded;

package body Synapse.Adapters.Fake_Extractor is

   procedure Script (F : in out Fake; Path : String; Answer : Port.Outcome) is
   begin
      F.Scripted.Include (Path, Answer);
   end Script;

   procedure Set_Default (F : in out Fake; Answer : Port.Outcome) is
   begin
      F.Default := Answer;
   end Set_Default;

   function Calls (F : Fake) return Natural is (F.Count);

   function Seen (F : Fake) return Core.Text_Lists.Vector is (F.Asked);

   overriding function Extract
     (F : in out Fake; Root : String; Paths : Core.Text_Lists.Vector)
      return Port.Outcome_Vectors.Vector
   is
      pragma Unreferenced (Root);
      Result : Port.Outcome_Vectors.Vector;
   begin
      F.Count := F.Count + 1;
      for Path of Paths loop
         declare
            Name : constant String := Ada.Strings.Unbounded.To_String (Path);
         begin
            F.Asked.Append (Path);
            Result.Append
              (if F.Scripted.Contains (Name) then F.Scripted (Name)
               else F.Default);
         end;
      end loop;
      return Result;
   end Extract;

end Synapse.Adapters.Fake_Extractor;
