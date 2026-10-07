with Ada.Strings.Unbounded;

package body Synapse.Adapters.Fake_Extractor is

   use type Port.Outcome_Kind;

   protected body Mutex is
      entry Seize when not Held is
      begin
         Held := True;
      end Seize;

      procedure Release is
      begin
         Held := False;
      end Release;
   end Mutex;

   procedure Script (F : in out Fake; Path : String; Answer : Port.Outcome) is
   begin
      F.Scripted.Include (Path, Answer);
   end Script;

   procedure Script_Failure (F : in out Fake; Path : String) is
   begin
      F.Failing.Include (Path);
   end Script_Failure;

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
      F.Lock.Seize;
      F.Count := F.Count + 1;
      for Path of Paths loop
         declare
            Name : constant String := Ada.Strings.Unbounded.To_String (Path);
         begin
            if F.Failing.Contains (Name) then
               F.Lock.Release;
               raise Program_Error with Name;
            end if;
            F.Asked.Append (Path);
            Result.Append
              (if F.Scripted.Contains (Name) then F.Scripted (Name)
               else F.Default);
         end;
      end loop;
      F.Lock.Release;
      return Result;
   end Extract;

   overriding function Extract_Located
     (F : in out Fake; Root : String; Paths : Core.Text_Lists.Vector)
      return Port.Located_Outcome_Vectors.Vector
   is
      Plain : constant Port.Outcome_Vectors.Vector := Extract (F, Root, Paths);
      Result : Port.Located_Outcome_Vectors.Vector;
   begin
      for Item of Plain loop
         if Item.Kind = Port.Unsupported then
            Result.Append (Port.Located_Outcome'(Kind => Port.Unsupported));
         else
            declare
               Spanned : Port.Located_Vectors.Vector;
            begin
               for Tag of Item.Tags loop
                  Spanned.Append
                    (Port.Located_Tag'
                       (Item  => Tag,
                        Where =>
                          (Start_Row => Tag.Line, Start_Col => 0,
                           End_Row   => Tag.Line,
                           End_Col   =>
                             Ada.Strings.Unbounded.Length (Tag.Name))));
               end loop;
               Result.Append
                 (Port.Located_Outcome'
                    (Kind => Port.With_Tags, Tags => Spanned));
            end;
         end if;
      end loop;
      return Result;
   end Extract_Located;

end Synapse.Adapters.Fake_Extractor;
