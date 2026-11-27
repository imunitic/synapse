with AUnit.Assertions;

with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Harnesses;

package body Synapse.Pipeline.Definition_Copies.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function U (Text : String) return Unbounded_String renames
     To_Unbounded_String;

   function Text (Words : String) return Resolved.Instruction is
     (Present => True, Text => U (Words));

   function Origin
     (Kind : Resolved.Origin_Kind; Name, File : String)
      return Resolved.Origin
   is (Kind => Kind, Name => U (Name), File => U (File));

   --  Two steps built from the same system, and from one Prompt definition
   --  that both use.
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
      First.Origins.Append
        (Origin (Resolved.Prompt_Origin, "Do_It", "/d/Do_It.synapse"));
      First.Assignment := Text ("Do it.");
      Second.Origins.Append
        (Origin (Resolved.System_Origin, "S", "/d/S.synapse"));
      Second.Origins.Append
        (Origin (Resolved.Prompt_Origin, "Do_It", "/d/Do_It.synapse"));
      Second.Role := Text ("Do it.");
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

   procedure A_Prompt_Definition_A_Step_Uses_Is_Copied_Into_The_Record
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/d/P.synapse", "pipeline text");
      F.Add_File ("/d/Do_It.synapse", "Prompt Do_It [Prompt => ""Do it.""];");
      declare
         Items : constant Copy_Vectors.Vector :=
           Collect (F, Pipeline, "/d/P.synapse");
      begin
         Assert
           (Names (Items) =
            "synapse-pipeline/P.synapse;synapse-pipeline/Do_It.synapse;",
            "the prompt is kept under its name, once: " & Names (Items));
         Assert
           (To_String (Items (Items.Last_Index).Content) =
            "Prompt Do_It [Prompt => ""Do it.""];",
            "with the text of its file");
      end;
   end A_Prompt_Definition_A_Step_Uses_Is_Copied_Into_The_Record;

   procedure The_Files_A_Run_Used_Are_Collected_By_Their_Configuration_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/d/P.synapse", "pipeline text");
      F.Add_File ("/d/S.synapse", "system text");
      F.Add_File ("/d/Ag.synapse", "agent text");
      F.Add_File ("/d/Do_It.synapse", "prompt text");
      declare
         Items : constant Copy_Vectors.Vector :=
           Collect (F, Pipeline, "/d/P.synapse");
      begin
         Assert
           (Names (Items) =
            "synapse-pipeline/P.synapse;synapse-pipeline/S.synapse;"
            & "synapse-pipeline/Ag.synapse;"
            & "synapse-pipeline/Do_It.synapse;",
            "the pipeline, then what its steps were built from, each once: "
            & Names (Items));
         Assert
           (To_String (Items (Items.First_Index).Content) = "pipeline text"
            and then To_String (Items (Items.Last_Index).Content) =
                     "prompt text",
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
           Collect (F, Pipeline, "/d/P.synapse");
      begin
         Assert
           (Names (Items) = "synapse-pipeline/P.synapse;",
            "a system, an agent and a prompt that are gone leave the rest: "
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
        (Names (Collect (F, Pipeline, "/d/P.synapse")) =
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
        (T, A_Prompt_Definition_A_Step_Uses_Is_Copied_Into_The_Record'Access,
         "A Prompt definition a step uses is copied into the record");
      Register_Routine
        (T, A_File_That_Cannot_Be_Read_Is_Left_Out'Access,
         "A file that cannot be read is left out");
      Register_Routine
        (T, A_Pipeline_That_Cannot_Be_Read_Gives_Only_The_Rest'Access,
         "A pipeline that cannot be read gives only the rest");
   end Register_Tests;

end Synapse.Pipeline.Definition_Copies.Tests;
