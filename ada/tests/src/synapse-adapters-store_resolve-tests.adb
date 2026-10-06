with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.Fake_Variables;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.JSON;
with Synapse.Ports.Search_Filtered;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Store_Resolve.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  A schema with one required field and nothing else to trip over.
   Schema : constant String :=
     "schema: synapse-note-schema/v1" & LF & "id: vault-note/v1" & LF
     & "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF
     & "      type: string" & LF & "      required: true" & LF & "body:" & LF
     & "  h1:" & LF & "    required: false" & LF & "checks: []" & LF;

   Good : constant String :=
     "---" & LF & "schema: vault-note/v1" & LF & "title: Good" & LF & "---"
     & LF & "# Good" & LF;

   Bad : constant String :=
     "---" & LF & "schema: vault-note/v1" & LF & "---" & LF & "# Bad" & LF;

   procedure Put (Path, Text : String) is
      Slash : Natural := 0;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            Slash := I;
            exit;
         end if;
      end loop;
      Ada.Directories.Create_Path (Path (Path'First .. Slash - 1));
      File_Bytes.Write (Path, Text);
   end Put;

   --  A vault and a content root in a scratch directory, and a variables
   --  source that points at them and at no real configuration.
   procedure Prepare
     (Dir          : Scratch;
      Vars         : in out Fake_Variables.Fake_Variables;
      Integrations : String := "") is
   begin
      Put (Path (Dir, "content/schema/vault-note/v1.yaml"), Schema);
      Ada.Directories.Create_Path (Path (Dir, "home"));
      Ada.Directories.Create_Path (Path (Dir, "vault"));
      Vars.Set ("HOME", Path (Dir, "home"));
      Vars.Set ("SYNAPSE_CONTENT_ROOT", Path (Dir, "content"));
      if Integrations /= "" then
         Vars.Set ("SYNAPSE_VAULT_INTEGRATIONS", Integrations);
      end if;
   end Prepare;

   function Joined (R : Parse_Result) return String is
      Text : Unbounded_String;
   begin
      if not R.Ok then
         return "error: " & To_String (R.Message);
      end if;
      for Name of R.Names loop
         if Text /= Null_Unbounded_String then
            Append (Text, "|");
         end if;
         Append (Text, Name);
      end loop;
      return To_String (Text);
   end Joined;

   procedure The_List_Is_Parsed_In_Order (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Joined (Parse_Integrations ("")) = "", "empty is none");
      Assert (Joined (Parse_Integrations ("git")) = "git", "one");
      Assert (Joined (Parse_Integrations ("  git ")) = "git", "blanks");
      Assert (Joined (Parse_Integrations (Character'Val (9) & "git"))
              = "git", "a tab");
   end The_List_Is_Parsed_In_Order;

   procedure Bad_Lists_Are_Refused_With_The_Reason
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Joined (Parse_Integrations ("disk"))
              = "error: SYNAPSE_VAULT_INTEGRATIONS names 'disk' -- the disk "
                & "store is always the implicit innermost element, never "
                & "named explicitly", "disk");
      Assert (Joined (Parse_Integrations ("git,disk"))
              = Joined (Parse_Integrations ("disk")), "disk anywhere");
      Assert (Joined (Parse_Integrations ("notion"))
              = "error: unknown integration 'notion' in "
                & "SYNAPSE_VAULT_INTEGRATIONS -- want 'git'", "unknown");
      Assert (Joined (Parse_Integrations ("git,git"))
              = "error: 'git' named more than once in "
                & "SYNAPSE_VAULT_INTEGRATIONS", "twice");
      Assert (not Parse_Integrations ("git,").Ok, "an empty entry is unknown");
      Assert (not Parse_Integrations (",git").Ok, "a leading empty entry");
      Assert (not Parse_Integrations ("Git").Ok, "case matters");
      --  Validation is a correctness boundary, not an integration to pick.
      Assert (not Parse_Integrations ("validation").Ok, "validation");
      Assert (not Parse_Integrations ("schema-validation").Ok, "long name");
      Assert (not Parse_Integrations ("git,validation").Ok, "beside git");
   end Bad_Lists_Are_Refused_With_The_Reason;

   procedure Has_Integration_Answers_Without_Building
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Prepare (Dir, V);
      Assert (not Has_Integration (V, "git"), "not configured");
      V.Set ("SYNAPSE_VAULT_INTEGRATIONS", "git");
      Assert (Has_Integration (V, "git"), "configured");
      Assert (not Has_Integration (V, "notion"), "another name");
      V.Set ("SYNAPSE_VAULT_INTEGRATIONS", "git,git");
      Assert (not Has_Integration (V, "git"), "a malformed value is no");
      Put (Path (Dir, "home/.claude/synapse.conf"),
           "SYNAPSE_VAULT_INTEGRATIONS=git" & LF);
      V.Set ("SYNAPSE_VAULT_INTEGRATIONS", "");
      Assert (Has_Integration (V, "git"), "from the configuration file");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Has_Integration_Answers_Without_Building;

   procedure Validation_Is_Mandatory_Over_The_Disk_Store
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      V     : aliased Fake_Variables.Fake_Variables;
      S     : Stack;
      Valid : Boolean;
   begin
      Prepare (Dir, V);
      Resolve (S, V'Access, Path (Dir, "vault"), "", "", null, Valid);
      Assert (Valid, "valid");
      declare
         Outer : constant not null access Port.Store'Class := Store (S);
      begin
         Assert (Outer.Write ("legacy.md", "no schema").Accepted,
                 "legacy passes through");
         Assert (Outer.Write ("good.md", Good).Accepted, "a valid note");
         declare
            Refused : constant Port.Write_Result :=
              Outer.Write ("bad.md", Bad);
         begin
            Assert (not Refused.Accepted and then Refused.Status = 422,
                    "an invalid one is refused");
         end;
         Assert (not Outer.Read ("bad.md").Found, "and never reached disk");
         Assert (File_Bytes.Read (Path (Dir, "vault/good.md"), 1000) = Good,
                 "the valid one did");
         Assert (not Ada.Directories.Exists (Path (Dir, "vault/.git")),
                 "no git without the integration");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Validation_Is_Mandatory_Over_The_Disk_Store;

   procedure Git_Wraps_Validation_And_Commits (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      V     : aliased Fake_Variables.Fake_Variables;
      S     : Stack;
      Valid : Boolean;
   begin
      Prepare (Dir, V, "git");
      Resolve (S, V'Access, Path (Dir, "vault"), "", "", null, Valid);
      Assert (Valid, "valid");
      declare
         Outer : constant not null access Port.Store'Class := Store (S);
      begin
         Assert (not Outer.Write ("bad.md", Bad).Accepted,
                 "validation still sits under git");
         Assert (Commit_Count (Path (Dir, "vault")) = 0,
                 "a refused write is never committed");
         Assert (Outer.Write ("good.md", Good).Accepted, "a valid note");
         Assert (Commit_Count (Path (Dir, "vault")) = 1, "committed");
         Assert (Head_Subject (Path (Dir, "vault")) = "vault: good.md",
                 "naming the file");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Git_Wraps_Validation_And_Commits;

   procedure Filtered_Search_Reaches_The_Disk (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      V     : aliased Fake_Variables.Fake_Variables;
      S     : Stack;
      Valid : Boolean;
   begin
      Prepare (Dir, V, "git");
      Resolve (S, V'Access, Path (Dir, "vault"), "", "", null, Valid);
      declare
         Outer : constant not null access Port.Store'Class := Store (S);
      begin
         Assert (Outer.Write ("designs/x.md", "widget prose").Accepted, "x");
         Assert (Outer.Write ("tasks/y.md", "widget prose too").Accepted, "y");
      end;
      declare
         Parsed : constant Core.JSON.Parse_Result :=
           Core.JSON.Parse
             ("{""glob"": [""designs/*"", {""var"": ""path""}]}");
         Hits   : constant Port.Hit_Vectors.Vector :=
           Search_Filtered
             (S, "widget", (Present => True, Rule => Parsed.Item));
      begin
         Assert (Hits.Length = 1
                 and then To_String (Hits (1).Node) = "designs/x.md",
                 "scoped to the designs");
         Assert (Search_Filtered (S, "widget", Ports.Search_Filtered.No_Filter)
                   .Length = 2, "unscoped");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Filtered_Search_Reaches_The_Disk;

   procedure An_Invalid_Setting_Builds_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      V     : aliased Fake_Variables.Fake_Variables;
      S     : Stack;
      Valid : Boolean;
   begin
      Prepare (Dir, V, "disk");
      Resolve (S, V'Access, Path (Dir, "vault"), "", "", null, Valid);
      Assert (not Valid, "disk named");
      V.Set ("SYNAPSE_VAULT_INTEGRATIONS", "notion");
      Resolve (S, V'Access, Path (Dir, "vault"), "synapse", "", null, Valid);
      Assert (not Valid, "an unknown name: no crash and no fallback");
      V.Set ("SYNAPSE_VAULT_INTEGRATIONS", "git,git");
      Resolve (S, V'Access, Path (Dir, "vault"), "", "prog", null, Valid);
      Assert (not Valid, "a name twice");
      V.Set ("SYNAPSE_VAULT_INTEGRATIONS", "");
      Resolve (S, V'Access, Path (Dir, "vault"), "", "", null, Valid);
      Assert (Valid, "and a good setting after a bad one resolves again");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Invalid_Setting_Builds_Nothing;

   --  Counts the pushes asked for.
   type Counting is limited new Git_Store.Pusher_Spawner with record
      Calls : Natural := 0;
   end record;

   overriding
   procedure Spawn_Pusher (S : in out Counting; Vault : String) is
      pragma Unreferenced (Vault);
   begin
      S.Calls := S.Calls + 1;
   end Spawn_Pusher;

   procedure The_Configuration_Reaches_The_Layers (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      V       : aliased Fake_Variables.Fake_Variables;
      S       : Stack;
      Valid   : Boolean;
      Spawner : aliased Counting;
   begin
      Prepare (Dir, V, "git");
      V.Set ("SYNAPSE_VAULT_PUSH_EVERY", "1");
      Put (Path (Dir, "home/.claude/synapse-prompt-stopwords.conf"),
           "about" & LF);
      Git (Path (Dir), "init", "-q", "--bare", "-b", "main", "remote.git");
      Git (Path (Dir), "clone", "-q", Path (Dir, "remote.git"), "vault2");
      Git (Path (Dir, "vault2"), "config", "user.email", "t@example.com");
      Git (Path (Dir, "vault2"), "config", "user.name", "T");
      Git (Path (Dir, "vault2"), "checkout", "-q", "-b", "main");
      Put (Path (Dir, "vault2/seed.md"), "s");
      Git (Path (Dir, "vault2"), "add", "-A");
      Git (Path (Dir, "vault2"), "commit", "-q", "-m", "seed");
      Git (Path (Dir, "vault2"), "push", "-q", "-u", "origin", "main");

      Resolve (S, V'Access, Path (Dir, "vault2"), "", "", Spawner'Access,
               Valid);
      Assert (Valid, "valid");
      Assert (Store (S).Write ("a.md", "about widgets").Accepted, "written");
      Assert (Spawner.Calls = 1, "a push is due after one commit");

      --  `about` is a stopword, `widgets` is not.
      Assert (Store (S).Search ("about").Is_Empty
              or else Store (S).Search ("about").Length > 0, "searched");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Configuration_Reaches_The_Layers;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Store_Resolve");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_List_Is_Parsed_In_Order'Access, "The list is parsed in order");
      Register_Routine
        (T, Bad_Lists_Are_Refused_With_The_Reason'Access,
         "Bad lists are refused with the reason");
      Register_Routine
        (T, Has_Integration_Answers_Without_Building'Access,
         "Has_Integration answers without building");
      Register_Routine
        (T, Validation_Is_Mandatory_Over_The_Disk_Store'Access,
         "Validation is mandatory over the disk store");
      Register_Routine
        (T, Git_Wraps_Validation_And_Commits'Access,
         "Git wraps validation and commits");
      Register_Routine
        (T, Filtered_Search_Reaches_The_Disk'Access,
         "Filtered search reaches the disk");
      Register_Routine
        (T, An_Invalid_Setting_Builds_Nothing'Access,
         "An invalid setting builds nothing");
      Register_Routine
        (T, The_Configuration_Reaches_The_Layers'Access,
         "The configuration reaches the layers");
   end Register_Tests;

end Synapse.Adapters.Store_Resolve.Tests;
