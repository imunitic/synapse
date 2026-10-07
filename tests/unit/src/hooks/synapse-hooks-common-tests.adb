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

package body Synapse.Hooks.Common.Tests is

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

   procedure The_Payload_Gives_Its_String_Fields (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Feed
        (F,
         "{""prompt"": ""hi"", ""cwd"": """", ""n"": 1, ""tool_input"": {""file_path"": ""/a/b.ext"", ""n"": 2}}");
      declare
         P : constant Common.Payload := Common.Read (Env (F));
      begin
         Assert
           (Common.Str (P, "prompt").Found
            and then To_String (Common.Str (P, "prompt").Value) = "hi",
            "a string");
         Assert (not Common.Str (P, "cwd").Found, "an empty one is none");
         Assert (not Common.Str (P, "n").Found, "a number is none");
         Assert (not Common.Str (P, "missing").Found, "an absent one");
         Assert
           (To_String (Common.Nested (P, "tool_input", "file_path").Value) =
            "/a/b.ext",
            "a nested one");
         Assert
           (not Common.Nested (P, "tool_input", "n").Found, "a nested number");
         Assert (not Common.Nested (P, "nope", "x").Found, "an absent object");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Payload_Gives_Its_String_Fields;

   procedure A_Payload_That_Is_Not_An_Object_Has_No_Fields
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Feed (F, "not json");
      Assert
        (not Common.Str (Common.Read (Env (F)), "prompt").Found, "garbage");
      Feed (F, "[1, 2]");
      Assert
        (not Common.Str (Common.Read (Env (F)), "prompt").Found, "an array");
      Feed (F, "");
      Assert (not Common.Str (Common.Read (Env (F)), "prompt").Found, "empty");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Payload_That_Is_Not_An_Object_Has_No_Fields;

   procedure The_Tool_S_File_Comes_From_Whichever_Field_Names_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Feed (F, "{""tool_input"": {""file_path"": ""/a/b.ml""}}");
      Assert
        (To_String (Common.Tool_File (Common.Read (Env (F))).Value) =
         "/a/b.ml",
         "file_path");
      Feed (F, "{""tool_response"": {""filePath"": ""/a/c.ml""}}");
      Assert
        (To_String (Common.Tool_File (Common.Read (Env (F))).Value) =
         "/a/c.ml",
         "filePath");
      Feed
        (F,
         "{""tool_input"": {""file_path"": ""/first.ml""}, ""tool_response"": {""filePath"": ""/second.ml""}}");
      Assert
        (To_String (Common.Tool_File (Common.Read (Env (F))).Value) =
         "/first.ml",
         "file_path wins");
      Feed (F, "{}");
      Assert (not Common.Tool_File (Common.Read (Env (F))).Found, "none");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Tool_S_File_Comes_From_Whichever_Field_Names_It;

   procedure An_Apply_Patch_Names_Its_File_Relative_To_The_Payload_S_Cwd
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Feed
        (F,
         "{""cwd"": ""/repo"", ""tool_input"": {""command"": ""*** Begin Patch\n*** Update File: lib/calc.ml\n@@\n-old\n+new\n*** End Patch""}}");
      Assert
        (To_String (Common.Tool_File (Common.Read (Env (F))).Value) =
         "/repo/lib/calc.ml",
         "update");
      Feed
        (F,
         "{""cwd"": ""/repo"", ""tool_input"": {""command"": ""*** Begin Patch\n*** Add File: brand/new.txt\n+content\n*** End Patch""}}");
      Assert
        (To_String (Common.Tool_File (Common.Read (Env (F))).Value) =
         "/repo/brand/new.txt",
         "add");
      Feed
        (F,
         "{""cwd"": ""/repo"", ""tool_input"": {""command"": ""*** Begin Patch\n*** Update File: /elsewhere/calc.ml\n*** End Patch""}}");
      Assert
        (To_String (Common.Tool_File (Common.Read (Env (F))).Value) =
         "/elsewhere/calc.ml",
         "absolute stays");
      Feed
        (F,
         "{""cwd"": ""/repo"", ""tool_input"": {""command"": ""*** Begin Patch\n*** Delete File: gone.ml\n*** End Patch""}}");
      Assert
        (not Common.Tool_File (Common.Read (Env (F))).Found,
         "a delete names none");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Apply_Patch_Names_Its_File_Relative_To_The_Payload_S_Cwd;

   procedure The_Vault_Is_A_Configured_Directory (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert
        (Common.Vault (Env (F)).Found
         and then To_String (Common.Vault (Env (F)).Value) =
           Path (Dir, "vault"),
         "found");
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "nowhere"));
      Assert
        (not Common.Vault (Env (F)).Found, "a directory that is not there");
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "afile"), "x");
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "afile"));
      Assert (not Common.Vault (Env (F)).Found, "a file");
      F.Vars.Set ("SYNAPSE_VAULT_DIR", "");
      F.Vars.Set ("HOME", Path (Dir, "empty-home"));
      Assert (not Common.Vault (Env (F)).Found, "none configured");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Vault_Is_A_Configured_Directory;

   procedure The_Namespace_Comes_From_The_Environment_Only_When_All_Three_Are_Set
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      declare
         Found : constant Common.Maybe_Namespace :=
           Common.Resolve_Namespace (Env (F), "/nowhere");
      begin
         Assert (Found.Found, "from the environment, wherever Cwd is");
         Assert
           (To_String (Found.Value.Key) = "widget@main"
            and then To_String (Found.Value.Branch) = "main"
            and then To_String (Found.Value.Remote) = Remote,
            "its fields");
      end;
      F.Vars.Set ("SYNAPSE_BRANCH", "");
      Assert
        (not Common.Resolve_Namespace (Env (F), "/nowhere").Found,
         "two of three is not enough");
      F.Vars.Set ("SYNAPSE_REMOTE", "");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      Assert
        (To_String
           (Common.Resolve_Namespace (Env (F), "/nowhere").Value.Remote) =
         "",
         "an empty remote is a real setting");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Namespace_Comes_From_The_Environment_Only_When_All_Three_Are_Set;

   procedure The_Namespace_Of_A_Checkout_Comes_From_Git
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put_File (Dir, "a.txt", "a");
      Commit_All (Dir);
      Git (Repo (Dir), "remote", "add", "origin", Remote);
      declare
         Found : constant Common.Maybe_Namespace :=
           Common.Resolve_Namespace (Env (F), Repo (Dir));
      begin
         Assert (Found.Found, "found");
         Assert
           (To_String (Found.Value.Key) = "widget@main"
            and then To_String (Found.Value.Remote) = Remote,
            "named from the remote: " & To_String (Found.Value.Key));
      end;
      Git (Repo (Dir), "checkout", "-q", "--detach");
      Assert
        (not Common.Resolve_Namespace (Env (F), Repo (Dir)).Found,
         "a detached head has none");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Namespace_Of_A_Checkout_Comes_From_Git;

   procedure The_Work_Directory_Is_The_Variable_Or_The_Cache_Named_For_The_Key
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Assert
        (To_String (Common.Work_Dir (Env (F), "widget@main").Value) =
         Path (Dir, "home/.cache/synapse/work/widget@main"),
         "default");
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "w"));
      Assert
        (To_String (Common.Work_Dir (Env (F), "widget@main").Value) =
         Path (Dir, "w"),
         "named");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Work_Directory_Is_The_Variable_Or_The_Cache_Named_For_The_Key;

   procedure An_Index_Agrees_Only_On_Both_Remote_And_Branch
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      declare
         Ns : constant Common.Namespace :=
           (Key       => To_Unbounded_String ("r@main"),
            Repo_Root => To_Unbounded_String ("/r"),
            Branch    => To_Unbounded_String ("main"),
            Remote    => To_Unbounded_String ("ssh://x/r.git"));
      begin
         Assert
           (Common.Index_Agrees
              ("---" & LF & "remote: ""ssh://x/r.git""" & LF & "branch: main" &
               LF & "---" & LF,
               Ns),
            "agrees");
         Assert
           (not Common.Index_Agrees
              ("---" & LF & "remote: ""ssh://x/other.git""" & LF &
               "branch: main" & LF & "---" & LF,
               Ns),
            "another repo");
         Assert
           (not Common.Index_Agrees
              ("---" & LF & "remote: ""ssh://x/r.git""" & LF &
               "branch: feature" & LF & "---" & LF,
               Ns),
            "another branch");
         Assert
           (not Common.Index_Agrees
              ("---" & LF & "branch: main" & LF & "---" & LF, Ns),
            "no remote is a mismatch");
         Assert
           (not Common.Index_Agrees
              ("---" & LF & "remote: ""ssh://x/r.git""" & LF & "---" & LF, Ns),
            "no branch is a mismatch");
      end;
      declare
         Bare : constant Common.Namespace :=
           (Key       => To_Unbounded_String ("r@main"),
            Repo_Root => To_Unbounded_String ("/r"),
            Branch    => To_Unbounded_String ("main"),
            Remote    => Null_Unbounded_String);
      begin
         Assert
           (not Common.Index_Agrees
              ("---" & LF & "remote: """"" & LF & "branch: main" & LF & "---" &
               LF,
               Bare),
            "an empty remote matches nothing, even an empty one");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Index_Agrees_Only_On_Both_Remote_And_Branch;

   procedure Context_Goes_Out_As_The_One_JSON_Shape
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Common.Emit_Context (Env (F), "Stop", "hello");
      Assert
        (F.Console.Out_Text =
         "{""hookSpecificOutput"":{""hookEventName"":""Stop"",""additionalContext"":""hello""}}" &
         LF,
         "the line: " & F.Console.Out_Text);
      F.Console.Clear;
      Common.Emit_Context (Env (F), "Stop", "");
      Assert (F.Console.Out_Text = "", "nothing for an empty text");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Context_Goes_Out_As_The_One_JSON_Shape;

   procedure A_JSON_String_Escapes_What_It_Must (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert
        (Common.Json_String ("a""b\c") = """a\""b\\c""",
         "quote and backslash");
      Assert
        (Common.Json_String ("x" & LF & "y" & ASCII.CR & ASCII.HT) =
         """x\ny\r\t""",
         "line feed, return, tab");
      Assert
        (Common.Json_String ("" & Character'Val (1) & Character'Val (31)) =
         """\u0001\u001f""",
         "control characters");
      Assert
        (Common.Json_String
           ("caf" & Character'Val (16#C3#) & Character'Val (16#A9#)) =
         """caf" & Character'Val (16#C3#) & Character'Val (16#A9#) & """",
         "bytes above 127 stay as they are");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_JSON_String_Escapes_What_It_Must;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Hooks.Common");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Payload_Gives_Its_String_Fields'Access,
         "The payload gives its string fields");
      Register_Routine
        (T, A_Payload_That_Is_Not_An_Object_Has_No_Fields'Access,
         "A payload that is not an object has no fields");
      Register_Routine
        (T, The_Tool_S_File_Comes_From_Whichever_Field_Names_It'Access,
         "The tool's file comes from whichever field names it");
      Register_Routine
        (T, An_Apply_Patch_Names_Its_File_Relative_To_The_Payload_S_Cwd'Access,
         "An apply_patch names its file relative to the payload's cwd");
      Register_Routine
        (T, The_Vault_Is_A_Configured_Directory'Access,
         "The vault is a configured directory");
      Register_Routine
        (T,
         The_Namespace_Comes_From_The_Environment_Only_When_All_Three_Are_Set'
           Access,
         "The namespace comes from the environment only when all three are set");
      Register_Routine
        (T, The_Namespace_Of_A_Checkout_Comes_From_Git'Access,
         "The namespace of a checkout comes from git");
      Register_Routine
        (T,
         The_Work_Directory_Is_The_Variable_Or_The_Cache_Named_For_The_Key'
           Access,
         "The work directory is the variable or the cache named for the key");
      Register_Routine
        (T, An_Index_Agrees_Only_On_Both_Remote_And_Branch'Access,
         "An index agrees only on both remote and branch");
      Register_Routine
        (T, Context_Goes_Out_As_The_One_JSON_Shape'Access,
         "Context goes out as the one JSON shape");
      Register_Routine
        (T, A_JSON_String_Escapes_What_It_Must'Access,
         "A JSON string escapes what it must");
   end Register_Tests;

end Synapse.Hooks.Common.Tests;
