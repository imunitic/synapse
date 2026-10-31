with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.Fake_Variables;

package body Synapse.Pipeline.Configs.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Harnesses.Harness_Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  The configuration the variables give, which must resolve.
   function Resolved_From
     (V : Synapse.Adapters.Fake_Variables.Fake_Variables) return Config
   is
      R : constant Config_Results.Result := Resolve (V, "/w");
   begin
      Assert
        (Config_Results.Is_Success (R),
         "resolves: "
         & (if Config_Results.Is_Success (R) then ""
            else To_String (Config_Results.Error (R))));
      return Config_Results.Value_Or (R, Config'(others => <>));
   end Resolved_From;

   --  Resolving must fail, saying Message.
   procedure Assert_Fails
     (V : Synapse.Adapters.Fake_Variables.Fake_Variables;
      Message, Label : String)
   is
      R : constant Config_Results.Result := Resolve (V, "/w");
   begin
      Assert (not Config_Results.Is_Success (R), Label & ": fails");
      if not Config_Results.Is_Success (R) then
         Assert
           (Ada.Strings.Fixed.Index
              (To_String (Config_Results.Error (R)), Message) > 0,
            Label & ": says '" & Message & "', says "
            & To_String (Config_Results.Error (R)));
      end if;
   end Assert_Fails;

   procedure Nothing_Set_Gives_The_Defaults (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
      C : constant Config := Resolved_From (V);
   begin
      Assert
        (C.Default_Timeout_Seconds = 1800 and then C.Step_Ceiling = 50,
         "30 minutes and 50 steps");
      Assert
        (C.Runner = Process_Runner and then Length (C.Script) = 0
         and then not C.Default_Harness.Found,
         "the process runner, no script, no default harness");
      Assert
        (C.Environment.Is_Empty
         and then To_String (C.Working_Directory) = "/w",
         "nothing captured, and where the caller is");
   end Nothing_Set_Gives_The_Defaults;

   procedure Every_Variable_Is_Read (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      V.Set (Timeout_Variable, "45m");
      V.Set (Ceiling_Variable, "12");
      V.Set (Runner_Variable, "scripted");
      V.Set (Script_Variable, "/answers.json");
      V.Set (Harnesses.Default_Variable, "Codex");
      V.Set (Vault_Dir_Key, "/vault");
      V.Set (Work_Dir_Key, "/work");
      V.Set (Content_Root_Key, "/content");
      V.Set ("SYNAPSE_SOMETHING_ELSE", "not captured");
      declare
         C : constant Config := Resolved_From (V);
      begin
         Assert
           (C.Default_Timeout_Seconds = 2700 and then C.Step_Ceiling = 12,
            "the limits");
         Assert
           (C.Runner = Scripted_Runner
            and then To_String (C.Script) = "/answers.json",
            "the runner and its script");
         Assert
           (C.Default_Harness.Found
            and then C.Default_Harness.Value = Harnesses.Codex,
            "the default harness");
         Assert
           (Natural (C.Environment.Length) = 3
            and then C.Environment.Element (Vault_Dir_Key) = "/vault"
            and then C.Environment.Element (Work_Dir_Key) = "/work"
            and then C.Environment.Element (Content_Root_Key) = "/content",
            "the three settings sessions are given, and no others");
      end;
      V.Set (Vault_Dir_Key, "");
      Assert
        (not Resolved_From (V).Environment.Contains (Vault_Dir_Key),
         "an empty setting is not captured");
   end Every_Variable_Is_Read;

   procedure A_Variable_That_Is_Wrong_Is_Said_To_Be
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      V.Set (Timeout_Variable, "soon");
      Assert_Fails
        (V, "SYNAPSE_PIPELINE_TIMEOUT is 'soon', which is not a duration",
         "a timeout");
      V.Set (Timeout_Variable, "30m");
      V.Set (Ceiling_Variable, "0");
      Assert_Fails
        (V, "SYNAPSE_PIPELINE_MAX_STEPS is '0'", "a ceiling of nothing");
      V.Set (Ceiling_Variable, "many");
      Assert_Fails
        (V, "SYNAPSE_PIPELINE_MAX_STEPS is 'many'", "a ceiling in words");
      V.Set (Ceiling_Variable, "50");
      V.Set (Runner_Variable, "fast");
      Assert_Fails
        (V, "which is not 'process' or 'scripted'", "a runner");
      V.Set (Runner_Variable, "scripted");
      Assert_Fails
        (V, "is scripted, but SYNAPSE_PIPELINE_SCRIPT names no file",
         "scripted without a script");
      V.Set (Runner_Variable, "process");
      V.Set (Harnesses.Default_Variable, "Cluade");
      Assert_Fails
        (V, "SYNAPSE_PIPELINE_HARNESS is 'Cluade'", "a default harness");
   end A_Variable_That_Is_Wrong_Is_Said_To_Be;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Configs");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Nothing_Set_Gives_The_Defaults'Access,
         "Nothing set gives the defaults");
      Register_Routine
        (T, Every_Variable_Is_Read'Access, "Every variable is read");
      Register_Routine
        (T, A_Variable_That_Is_Wrong_Is_Said_To_Be'Access,
         "A variable that is wrong is said to be");
   end Register_Tests;

end Synapse.Pipeline.Configs.Tests;
