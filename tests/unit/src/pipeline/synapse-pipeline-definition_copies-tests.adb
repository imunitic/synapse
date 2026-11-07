with AUnit.Assertions;

with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Harnesses;

package body Synapse.Pipeline.Definition_Copies.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function U (Text : String) return Unbounded_String renames
     To_Unbounded_String;

   function Skill (Name : String) return Resolved.Instruction is
     (Present => True, Kind => Resolved.Skill_Name, Text => U (Name));

   function Origin
     (Kind : Resolved.Origin_Kind; Name, File : String)
      return Resolved.Origin
   is (Kind => Kind, Name => U (Name), File => U (File));

   function Roots return Search_Paths.Root_Vectors.Vector is
      Result : Search_Paths.Root_Vectors.Vector;
   begin
      Result.Append
        (Search_Paths.Root'(Path => U ("/skills"), Required => False));
      return Result;
   end Roots;

   --  Two steps built from the same system, and from skills, one of which no
   --  root holds.
   function Pipeline return Resolved.Pipeline is
      Result : Resolved.Pipeline;
      First  : Resolved.Step :=
        (Name => U ("A"), Harness => Harnesses.Claude, others => <>);
      Second : Resolved.Step :=
        (Name => U ("B"), Harness => Harnesses.Claude, others => <>);
   begin
      Result.Name := U ("P");
      First.Origins.Append
        (Origin (Resolved.System_Origin, "S", "/d/S.synapse"));
      First.Origins.Append
        (Origin (Resolved.Agent_Origin, "Ag", "/d/Ag.synapse"));
      First.Assignment := Skill ("do-it");
      Second.Origins.Append
        (Origin (Resolved.System_Origin, "S", "/d/S.synapse"));
      Second.Role := Skill ("do-it");
      Second.Assignment := Skill ("not-there");
      Result.Steps.Append (First);
      Result.Steps.Append (Second);
      return Result;
   end Pipeline;

   function Names (Items : Copy_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for Item of Items loop
         Append (Result, To_String (Item.Path) & ";");
      end loop;
      return To_String (Result);
   end Names;

   procedure The_Files_A_Run_Used_Are_Collected_By_Their_Configuration_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/d/P.synapse", "pipeline text");
      F.Add_File ("/d/S.synapse", "system text");
      F.Add_File ("/d/Ag.synapse", "agent text");
      F.Add_File ("/skills/do-it/SKILL.md", "skill text");
      declare
         Items : constant Copy_Vectors.Vector :=
           Collect (F, Pipeline, "/d/P.synapse", Roots);
      begin
         Assert
           (Names (Items) =
            "synapse-pipeline/P.synapse;synapse-pipeline/S.synapse;"
            & "synapse-pipeline/Ag.synapse;"
            & "synapse-pipeline/skills/do-it/SKILL.md;",
            "the pipeline, then what its steps were built from, then the "
            & "skills, each once: " & Names (Items));
         Assert
           (To_String (Items (Items.First_Index).Content) = "pipeline text"
            and then To_String (Items (Items.Last_Index).Content) =
                     "skill text",
            "with the text each file has");
      end;
   end The_Files_A_Run_Used_Are_Collected_By_Their_Configuration_Path;

   procedure A_File_That_Cannot_Be_Read_Is_Left_Out
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/d/P.synapse", "pipeline text");
      declare
         Items : constant Copy_Vectors.Vector :=
           Collect (F, Pipeline, "/d/P.synapse", Roots);
      begin
         Assert
           (Names (Items) = "synapse-pipeline/P.synapse;",
            "a system, an agent and skills that are gone leave the rest: "
            & Names (Items));
      end;
   end A_File_That_Cannot_Be_Read_Is_Left_Out;

   procedure A_Pipeline_That_Cannot_Be_Read_Gives_Only_The_Rest
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/d/S.synapse", "system text");
      Assert
        (Names (Collect (F, Pipeline, "/d/P.synapse", Roots)) =
         "synapse-pipeline/S.synapse;",
         "only what can be read is collected");
   end A_Pipeline_That_Cannot_Be_Read_Gives_Only_The_Rest;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Definition_Copies");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T,
         The_Files_A_Run_Used_Are_Collected_By_Their_Configuration_Path'
           Access,
         "The files a run used are collected by their configuration path");
      Register_Routine
        (T, A_File_That_Cannot_Be_Read_Is_Left_Out'Access,
         "A file that cannot be read is left out");
      Register_Routine
        (T, A_Pipeline_That_Cannot_Be_Read_Gives_Only_The_Rest'Access,
         "A pipeline that cannot be read gives only the rest");
   end Register_Tests;

end Synapse.Pipeline.Definition_Copies.Tests;
