with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with Synapse.Hooks.Common;
with AUnit.Assertions;

package body Synapse.Hooks.Stop_Nudge.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Remote : constant String := "https://example.com/o/widget.git";

   Engine_Source : constant String :=
     "pub fn start() void {}" & LF & "pub fn stop() void {}" & LF &
     "const x = 1;" & LF;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure Work (Dir : Scratch; Name, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path (Dir, "work/" & Name)));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work/" & Name), Text);
   end Work;

   function Node (Dir : Scratch; File : String) return String is
     (Synapse.Adapters.File_Bytes.Read
        (Path (Dir, "vault/synapse/widget@main/" & File), 1_000_000));

   --  The context pinned to a checkout on `main`; no graph yet.
   procedure Pin (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      F.Clock.Now := To_Unbounded_String ("2026-09-07T14:32:05+02:00");
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      Put_File (Dir, "src/engine.ext", Engine_Source);
      Put_File (Dir, "src/render.ext", "paint" & LF);
      Put_File (Dir, "README.md", "hello" & LF);
      Commit_All (Dir);
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", Repo (Dir));
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", Remote);
   end Pin;

   procedure Feed (F : aliased in out Fixture; Text : String) is
   begin
      F.Console.Set_Stdin (Text);
   end Feed;

   function Quote (Text : String) return String is ("""" & Text & """");

   procedure The_Nudge_Comes_On_The_Twenty_Fifth_Turn_And_Again_On_The_Fiftieth
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Feed (F, "{""session_id"": ""s1""}");
      Use_Vault (F, Dir);
      for I in 1 .. 24 loop
         Feed (F, "{""session_id"": ""s1""}");
         Run (Env (F));
      end loop;
      Assert (F.Console.Out_Text = "", "quiet until then");
      Feed (F, "{""session_id"": ""s1""}");
      Run (Env (F));
      Assert
        (Has (F.Console.Out_Text, """hookEventName"":""Stop"""), "the event");
      Assert
        (Has
           (F.Console.Out_Text,
            "This session has grown substantial (25 turns, re-armed at the 25-turn mark)."),
         "the count: " & F.Console.Out_Text);
      Assert
        (Has
           (F.Console.Out_Text,
            "persisting to Synapse Vault (" & Path (Dir, "vault") & ")?"),
         "names the vault");
      Assert
        (Has
           (F.Console.Out_Text,
            "see the global CLAUDE.md \""Synapse Vault as permanent memory\"" section"),
         "the heading: " & F.Console.Out_Text);
      F.Console.Clear;
      for I in 1 .. 24 loop
         Feed (F, "{""session_id"": ""s1""}");
         Run (Env (F));
      end loop;
      Assert (F.Console.Out_Text = "", "quiet again");
      Feed (F, "{""session_id"": ""s1""}");
      Run (Env (F));
      Assert
        (Has (F.Console.Out_Text, "(50 turns, re-armed"),
         "and the total keeps counting: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Nudge_Comes_On_The_Twenty_Fifth_Turn_And_Again_On_The_Fiftieth;

   procedure Sessions_Count_Apart_And_Without_A_Vault_The_Nudge_Says_So
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_VAULT_DIR", "");
      declare
         A : Tick_Result;
      begin
         for I in 1 .. 25 loop
            A := Tick (Env (F), Path (Dir, "home"), "one");
         end loop;
         Assert (A.Due and then A.Total = 25, "one is due");
         Assert
           (Has
              (To_String (A.Nudge),
               "persisting to Synapse Vault (the vault)?"),
            "no path to lie about");
         Assert
           (not Tick (Env (F), Path (Dir, "home"), "two").Due
            and then Tick (Env (F), Path (Dir, "home"), "two").Total = 2,
            "two has just begun");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Sessions_Count_Apart_And_Without_A_Vault_The_Nudge_Says_So;

   procedure The_Counters_Are_Files_In_The_State_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      declare
         Ignored : constant Tick_Result :=
           Tick (Env (F), Path (Dir, "home"), "abc");
         pragma Unreferenced (Ignored);
      begin
         Assert
           (Synapse.Adapters.File_Bytes.Read
              (Path (Dir, "home/.claude/state/synapse-stop-nudge-total-abc"),
               100) =
            "1" & LF,
            "total");
         Assert
           (Synapse.Adapters.File_Bytes.Read
              (Path (Dir, "home/.claude/state/synapse-stop-nudge-since-abc"),
               100) =
            "1" & LF,
            "since");
         Assert
           (not Ada.Directories.Exists
              (Path
                 (Dir, "home/.claude/state/synapse-stop-nudge-total-abc.tmp")),
            "no temporary file left");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Counters_Are_Files_In_The_State_Directory;

   procedure A_Counter_That_Cannot_Be_Read_Starts_Again_From_Zero_And_Says_So
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Ada.Directories.Create_Path (Path (Dir, "home/.claude/state"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "home/.claude/state/synapse-stop-nudge-total-s"),
         "zzz" & LF);
      declare
         Done : constant Tick_Result :=
           Tick (Env (F), Path (Dir, "home"), "s");
      begin
         Assert (Done.Total = 1, "from zero");
         Assert
           (Has
              (F.Console.Err_Text,
               "synapse-hook: corrupt stop-nudge counter, restarting from 0 ("),
            "said: " & F.Console.Err_Text);
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Counter_That_Cannot_Be_Read_Starts_Again_From_Zero_And_Says_So;

   procedure Nothing_Is_Counted_Without_A_Home (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Run (Env (F));
      Assert (F.Console.Out_Text = "", "quiet");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Nothing_Is_Counted_Without_A_Home;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Hooks.Stop_Nudge");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T,
         The_Nudge_Comes_On_The_Twenty_Fifth_Turn_And_Again_On_The_Fiftieth'
           Access,
         "The nudge comes on the twenty fifth turn and again on the fiftieth");
      Register_Routine
        (T, Sessions_Count_Apart_And_Without_A_Vault_The_Nudge_Says_So'Access,
         "Sessions count apart and without a vault the nudge says so");
      Register_Routine
        (T, The_Counters_Are_Files_In_The_State_Directory'Access,
         "The counters are files in the state directory");
      Register_Routine
        (T,
         A_Counter_That_Cannot_Be_Read_Starts_Again_From_Zero_And_Says_So'
           Access,
         "A counter that cannot be read starts again from zero and says so");
      Register_Routine
        (T, Nothing_Is_Counted_Without_A_Home'Access,
         "Nothing is counted without a home");
   end Register_Tests;

end Synapse.Hooks.Stop_Nudge.Tests;
