with Ada.Strings.Unbounded;

with Acceptance.Fixtures;

package body Acceptance.Prompt_Context_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  Enough of a namespace for the hook to have something to announce: an
   --  Index.md whose `remote` matches this repository, and one node so that
   --  the count is not zero (the hook is silent at zero nodes).
   procedure Make_Namespace (F : Fixture) is
      Name : constant String := Repo_Name (F);
   begin
      Write_Synapse_Index (F, Name, Repo_Remote_Or_Path (F));
      Write_File
        (Vault (F) & "/synapse/" & Name & "/Foo Node.md",
         "---" & LF & "title: ""Foo Node""" & LF & "node_type: synapse-node" &
         LF & "stale: false" & LF & "---" & LF & "# Foo Node" & LF);
   end Make_Namespace;

   function Run_Prompt (F : Fixture; Prompt : String) return Result is
     (Run_Hook_Stdin
        (F, "{""prompt"":""" & Prompt & """,""cwd"":""" & Repo (F) & """}",
         "prompt-context"));

   procedure A_Stdin_Payload_In_A_Namespace_Emits_The_Nudge
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F);
      Make_Namespace (F);
      declare
         R : constant Result :=
           Run_Prompt (F, "how does Cached_backend invalidate results");
         O : constant String := To_String (R.Output);
      begin
         Assert_Exit (R, 0, "prompt-context");
         Assert_Contains (O, "hookSpecificOutput", "hook output");
         Assert_Contains
           (O, "synapse/" & Repo_Name (F) & "/", "names the namespace");
         Assert_Contains (O, "1 nodes", "counts the nodes");
         --  The instruction and not a suggestion: the wording is the feature.
         Assert_Contains (O, "Query it FIRST", "instruction");
         Assert_Contains (O, "Do not grep or open source files", "order");
      end;
   end A_Stdin_Payload_In_A_Namespace_Emits_The_Nudge;

   procedure An_Empty_Prompt_Exits_Silently (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F);
      Make_Namespace (F);
      declare
         R : constant Result := Run_Prompt (F, "");
      begin
         Assert_Exit (R, 0, "prompt-context");
         Assert_Equal (To_String (R.Output), "", "stdout");
      end;
   end An_Empty_Prompt_Exits_Silently;

   procedure The_Disable_Switch_Short_Circuits (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F);
      Make_Namespace (F);
      Set_Env (F, "SYNAPSE_DISABLE_PROMPT_INJECTION", "1");
      declare
         R : constant Result :=
           Run_Prompt (F, "how does Cached_backend invalidate results");
      begin
         Assert_Exit (R, 0, "prompt-context");
         Assert_Equal (To_String (R.Output), "", "stdout");
      end;
   end The_Disable_Switch_Short_Circuits;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: prompt-context hook");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Stdin_Payload_In_A_Namespace_Emits_The_Nudge'Access,
         "a stdin payload in a repo with a namespace emits the nudge");
      Register_Routine
        (T, An_Empty_Prompt_Exits_Silently'Access,
         "an empty prompt exits silently");
      Register_Routine
        (T, The_Disable_Switch_Short_Circuits'Access,
         "SYNAPSE_DISABLE_PROMPT_INJECTION short-circuits");
   end Register_Tests;

end Acceptance.Prompt_Context_Tests;
