with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Acceptance.Fixtures;
with Synapse.Core.Text_Lists;

package body Acceptance.Legacy_Commands_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;

   package Sets renames Synapse.Core.Text_Lists.Sets;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Is_Lower (C : Character) return Boolean is (C in 'a' .. 'z');

   --  Every word matching `^  ([a-z][a-z-]*) ` in Text: the subcommand names
   --  a help listing documents, one per line.
   function Help_Names (Text : String) return Sets.Set is
      Result : Sets.Set;
   begin
      for Item of Lines (Text) loop
         declare
            Line : constant String := To_String (Item);
         begin
            if Starts_With (Line, "  ") and then Line'Length > 2
              and then Is_Lower (Line (Line'First + 2))
            then
               declare
                  Rest : constant String := Line (Line'First + 2 .. Line'Last);
                  Stop : Natural         := Rest'First;
               begin
                  while Stop <= Rest'Last
                    and then (Is_Lower (Rest (Stop)) or else Rest (Stop) = '-')
                  loop
                     Stop := Stop + 1;
                  end loop;
                  if Stop <= Rest'Last and then Rest (Stop) = ' ' then
                     Result.Include (Rest (Rest'First .. Stop - 1));
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Help_Names;

   function Names_From_Help (F : Fixture; Extra : String) return Sets.Set is
      R : constant Result :=
        (if Extra = "" then Run_Fake (F, "--help")
         else Run_Fake (F, Extra, "--help"));
   begin
      return Help_Names (To_String (R.Output) & LF & To_String (R.Errors));
   end Names_From_Help;

   --  Every `.md` basename, without its extension, under
   --  `packages/synapse/commands/`.
   function Shipped_Command_Names return Sets.Set is
      Result : Sets.Set;
   begin
      for Name of Files_In (Checkout & "/packages/synapse/commands", ".md")
      loop
         Result.Include (To_String (Name) (1 .. Length (Name) - 3));
      end loop;
      return Result;
   end Shipped_Command_Names;

   --  The word after Prefix, where Prefix follows a backtick, in each span
   --  that starts `Prefix: `synapse query ` gives `callers` from
   --  `` `synapse query callers` ``. Only a run of `[a-z-]` counts, and the
   --  first character must be a letter, or `--namespace` right after
   --  `synapse query ` would match as a subcommand.
   procedure Extract_After (Text, Prefix : String; Found : in out Sets.Set) is
      Pos : Natural := Text'First;
   begin
      while Pos <= Text'Last loop
         declare
            Start : constant Natural :=
              Ada.Strings.Fixed.Index (Text (Pos .. Text'Last), Prefix);
         begin
            exit when Start = 0;
            Pos := Start + 1;
            declare
               First : constant Natural := Start + Prefix'Length;
            begin
               if First <= Text'Last and then Is_Lower (Text (First))
                 and then Start > Text'First and then Text (Start - 1) = '`'
               then
                  declare
                     Stop : Natural := First + 1;
                  begin
                     while Stop <= Text'Last
                       and then
                       (Is_Lower (Text (Stop)) or else Text (Stop) = '-')
                     loop
                        Stop := Stop + 1;
                     end loop;
                     Found.Include (Text (First .. Stop - 1));
                  end;
               end if;
            end;
         end;
      end loop;
   end Extract_After;

   --  Every `synapse <sub>`, `synapse query <sub>` and `/synapse-<command>` in
   --  Text that does not exist. Empty means clean.
   function Unknown_Commands (F : Fixture; Text : String) return String is
      Subs : constant Sets.Set := Names_From_Help (F, "");
      Query_Subs : constant Sets.Set := Names_From_Help (F, "query");
      Commands : constant Sets.Set := Shipped_Command_Names;
      Query_Words, Words, Slash_Words : Sets.Set;
      Result                          : Unbounded_String;
   begin
      Extract_After (Text, "synapse query ", Query_Words);
      for W of Query_Words loop
         if not Query_Subs.Contains (W) then
            Append (Result, "  synapse query " & W & LF);
         end if;
      end loop;
      Extract_After (Text, "synapse ", Words);
      for W of Words loop
         if not Subs.Contains (W) then
            Append (Result, "  synapse " & W & LF);
         end if;
      end loop;
      Extract_After (Text, "/synapse-", Slash_Words);
      for W of Slash_Words loop
         if not Commands.Contains ("synapse-" & W) then
            Append (Result, "  /synapse-" & W & LF);
         end if;
      end loop;
      return To_String (Result);
   end Unknown_Commands;

   --  The contents of every `.md` file below Dir, one after another.
   function Markdown_Under (Dir : String) return String is
      Result : Unbounded_String;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      Ada.Directories.Start_Search
        (Search, Dir, "",
         [Ada.Directories.Ordinary_File | Ada.Directories.Directory => True,
         others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
            Full : constant String := Ada.Directories.Full_Name (Item);
            use type Ada.Directories.File_Kind;
         begin
            if Name in "." | ".." then
               null;
            elsif Ada.Directories.Kind (Item) = Ada.Directories.Directory then
               Append (Result, Markdown_Under (Full));
            elsif Name'Length > 3
              and then Name (Name'Last - 2 .. Name'Last) = ".md"
            then
               Append (Result, Read_File (Full) & LF);
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      return To_String (Result);
   end Markdown_Under;

   --  A node, as the writer leaves it: enough frontmatter for the index
   --  builder to read a summary back off it.
   procedure Stage_Node (F : Fixture; Title, Summary : String) is
      Name : constant String := Repo_Name (F);
   begin
      Write_File
        (Vault (F) & "/synapse/" & Name & "/" & Title & ".md",
         "---" & LF & "title: """ & Title & """" & LF & "summary: """ &
         Summary & """" & LF & "node_type: synapse-node" & LF & "project: " &
         Name & LF & "sources:" & LF & "  - path: src/foo.aa" & LF &
         "    hash: y" & LF & "sources_digest: deadbeef" & LF &
         "stale: false" & LF & "built_at: ""2026-01-01 00:00""" & LF & "---" &
         LF & LF & "# " & Title & LF & "<!-- synapse:generated:start -->" &
         LF & "body" & LF & "<!-- synapse:generated:end -->" & LF & LF &
         "## Notes" & LF);
   end Stage_Node;

   procedure Shipped_Instructions_Name_Real_Subcommands
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F);
      declare
         Bad : constant String :=
           Unknown_Commands
             (F, Markdown_Under (Checkout & "/packages/synapse"));
      begin
         Assert_Equal (Bad, "", "commands a shipped instruction names");
      end;
   end Shipped_Instructions_Name_Real_Subcommands;

   procedure Injected_Context_Names_Real_Commands (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F, "git@github.com:example/repo.git");
      Write_Synapse_Index (F, Repo_Name (F), Repo_Remote_Or_Path (F));
      Stage_Node (F, "Query API", "Conditions and validation.");
      Write_Index_Bin
        (F, Default_Work_Dir (F),
         "src/foo.aa" & ASCII.HT & "Query API.md" & LF);
      Write_File
        (Default_Work_Dir (F) & "/_refs.tsv",
         "foo" & ASCII.HT & "def" & ASCII.HT & "function" & ASCII.HT &
         "src/foo.aa" & ASCII.HT & "1" & ASCII.HT & "let foo x =" & LF);

      declare
         R1      : constant Result :=
           Run_Hook_Stdin
             (F,
              "{""prompt"":""how does Query API validate"",""cwd"":""" &
              Repo (F) & """}",
              "prompt-context");
         R2      : constant Result :=
           Run_Hook_Stdin
             (F, "{""cwd"":""" & Repo (F) & """}", "session-start");
         R3      : constant Result :=
           Run_Hook_Stdin
             (F,
              "{""tool_input"":{""file_path"":""" & Repo (F) &
              "/src/foo.aa""}}",
              "staleness");
         Emitted : constant String := Both (R1) & Both (R2) & Both (R3);
      begin
         Assert
           (To_String (R1.Output)'Length > 0, "prompt-context said something");
         Assert_Equal
           (Unknown_Commands (F, Emitted), "", "commands the hooks name");
      end;
   end Injected_Context_Names_Real_Commands;

   procedure A_Generated_Document_Names_Real_Commands
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F, "ssh://git@example.com/x/proj.git");
      Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
      Write_Work_File (F, "lists/01.title", "Query API" & LF);
      Write_Work_File (F, "lists/01.txt", "src/foo.aa" & LF);
      Stage_Node (F, "Query API", "Conditions and validation.");
      Assert_Exit
        (Run_Fake (F, "build-project-index"), 0, "build-project-index");
      declare
         Generated : constant String :=
           Read_File (Vault (F) & "/synapse/" & Repo_Name (F) & "/Index.md");
      begin
         Assert_Contains (Generated, "Reading a node", "the generated text");
         Assert_Equal
           (Unknown_Commands (F, Generated), "", "commands Index.md names");
      end;
   end A_Generated_Document_Names_Real_Commands;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: commands that texts name");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Shipped_Instructions_Name_Real_Subcommands'Access,
         "every 'synapse <sub>' a shipped instruction names is real");
      Register_Routine
        (T, Injected_Context_Names_Real_Commands'Access,
         "no context a hook injects names a command that does not exist");
      Register_Routine
        (T, A_Generated_Document_Names_Real_Commands'Access,
         "no generated document names a command that does not exist");
   end Register_Tests;

end Acceptance.Legacy_Commands_Tests;
