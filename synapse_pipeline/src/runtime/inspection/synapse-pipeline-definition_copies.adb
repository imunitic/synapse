with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Skills;

package body Synapse.Pipeline.Definition_Copies is

   use Ada.Strings.Unbounded;
   use type Resolved.Instruction_Kind;

   Directory : constant String := "synapse-pipeline/";

   function Join (Base, Name : String) return String is
     (if Base'Length > 0 and then Base (Base'Last) in '/' | '\'
      then Base & Name
      else Base & "/" & Name);

   function Collect
     (Files         : File_System.File_System'Class;
      Item          : Resolved.Pipeline;
      Pipeline_File : String;
      Skill_Roots   : Search_Paths.Root_Vectors.Vector)
      return Copy_Vectors.Vector
   is
      Result : Copy_Vectors.Vector;
      Seen   : Synapse.Core.Text_Lists.Sets.Set;

      --  Keeps the file Source under Path, once.
      procedure Add (Path, Source : String) is
         Found : constant File_System.Maybe_Content := Files.Read (Source);
      begin
         if Found.Found and then not Seen.Contains (Path) then
            Seen.Insert (Path);
            Result.Append
              (Copy'(Path    => To_Unbounded_String (Path),
                     Content => Found.Value));
         end if;
      end Add;

      procedure Add_Skill (Instruction : Resolved.Instruction) is
      begin
         if Instruction.Present
           and then Instruction.Kind = Resolved.Skill_Name
         then
            declare
               Name  : constant String := To_String (Instruction.Text);
               Found : constant Synapse.Core.Optional_Text.Option :=
                 Skills.Find (Files, Skill_Roots, Name);
            begin
               if Found.Found then
                  Add
                    (Directory & "skills/" & Name & "/SKILL.md",
                     Join (To_String (Found.Value), "SKILL.md"));
               end if;
            end;
         end if;
      end Add_Skill;
   begin
      Add (Directory & To_String (Item.Name) & ".synapse", Pipeline_File);
      for S of Item.Steps loop
         for O of S.Origins loop
            Add
              (Directory & To_String (O.Name) & ".synapse",
               To_String (O.File));
         end loop;
         Add_Skill (S.Role);
         Add_Skill (S.Assignment);
      end loop;
      return Result;
   end Collect;

end Synapse.Pipeline.Definition_Copies;
