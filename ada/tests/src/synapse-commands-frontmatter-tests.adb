with Ada.Strings.Unbounded;

with Synapse.Commands.Vault_Usage;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Frontmatter.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);

   Note : constant String :=
     "---" & LF & "title: ""Example""" & LF & "status: TODO" & LF &
     "tags: [x, y]" & LF & "---" & LF & "body" & LF & "status: BODY" & LF;

   procedure Parse_Takes_A_Path_And_A_Key_For_Get (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      declare
         Got : constant Request :=
           Parse (Args ("get", "tasks/x.md", "status"));
      begin
         Assert (Got.Op = Get, "a get");
         Assert (To_String (Got.Path) = "tasks/x.md", "the path");
         Assert (To_String (Got.Key) = "status", "the key");
      end;
   end Parse_Takes_A_Path_And_A_Key_For_Get;

   procedure Parse_Takes_A_Bare_Key_And_Value_For_Set
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      declare
         Got : constant Request :=
           Parse (Args ("set", "tasks/x.md", "status", "DONE"));
      begin
         Assert (Got.Op = Set_Value, "a set");
         Assert (To_String (Got.Path) = "tasks/x.md", "the path");
         Assert (To_String (Got.Key) = "status", "the key");
         Assert (To_String (Got.Value) = "DONE", "the value");
      end;
   end Parse_Takes_A_Bare_Key_And_Value_For_Set;

   procedure Parse_Takes_A_Tag_Flag_With_Only_A_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      declare
         Add    : constant Request :=
           Parse (Args ("set", "x.md", "--add-tag", "zig"));
         Remove : constant Request :=
           Parse (Args ("set", "--remove-tag", "zig", "x.md"));
      begin
         Assert
           (Add.Op = Add_Tag and then To_String (Add.Value) = "zig", "add");
         Assert
           (Remove.Op = Remove_Tag and then To_String (Remove.Value) = "zig"
            and then To_String (Remove.Path) = "x.md",
            "remove, the flag in front");
      end;
   end Parse_Takes_A_Tag_Flag_With_Only_A_Path;

   procedure Parse_Refuses_A_Tag_Flag_Together_With_A_Key_And_Value
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Parse (Args ("set", "x.md", "status", "DONE", "--add-tag", "zig"))
           .Op =
         Invalid,
         "after");
      Assert
        (Parse (Args ("set", "x.md", "--add-tag", "zig", "status", "DONE"))
           .Op =
         Invalid,
         "before");
      Assert
        (Parse (Args ("set", "x.md", "--add-tag", "a", "--remove-tag", "b"))
           .Op =
         Invalid,
         "two tag flags");
   end Parse_Refuses_A_Tag_Flag_Together_With_A_Key_And_Value;

   procedure Parse_Refuses_What_Is_Incomplete_Or_Unknown
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      declare
         Empty_Key  : Lists.Vector := Args ("get", "x.md");
         Empty_Path : Lists.Vector := Args ("get");
      begin
         Empty_Path.Append (Ada.Strings.Unbounded.Null_Unbounded_String);
         Empty_Path.Append (Ada.Strings.Unbounded.To_Unbounded_String ("k"));
         Assert (Parse (Empty_Path).Op = Invalid, "an empty path");
         Empty_Key.Append (Ada.Strings.Unbounded.Null_Unbounded_String);
         Assert (Parse (Empty_Key).Op = Invalid, "an empty key");
      end;
      Assert (Parse (Args).Op = Invalid, "nothing");
      Assert
        (Parse (Args ("set", "x.md", "k", "v", "extra")).Op = Invalid,
         "a fourth word");
      Assert (Parse (Args ("get")).Op = Invalid, "get alone");
      Assert (Parse (Args ("get", "x.md")).Op = Invalid, "get without a key");
      Assert
        (Parse (Args ("get", "x.md", "k", "extra")).Op = Invalid, "extra");
      Assert (Parse (Args ("set")).Op = Invalid, "set alone");
      Assert (Parse (Args ("set", "x.md")).Op = Invalid, "set with a path");
      Assert (Parse (Args ("set", "x.md", "k")).Op = Invalid, "no value");
      Assert
        (Parse (Args ("set", "x.md", "--add-tag")).Op = Invalid, "no tag");
      Assert (Parse (Args ("del", "x.md", "k")).Op = Invalid, "unknown word");
   end Parse_Refuses_What_Is_Incomplete_Or_Unknown;

   procedure Get_Prints_A_Field_As_Written (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "tasks/x.md", Note);
      Assert (Run (Env (F), Args ("get", "tasks/x.md", "title")) = 0, "ok");
      Assert (F.Console.Out_Text = "Example" & LF, "one quote off each end");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("get", "tasks/x.md", "tags")) = 0, "list");
      Assert (F.Console.Out_Text = "[x, y]" & LF, "the list as written");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Get_Prints_A_Field_As_Written;

   procedure Get_Of_An_Absent_Key_Prints_Nothing_And_Succeeds
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "x.md", Note);
      Assert (Run (Env (F), Args ("get", "x.md", "nope")) = 0, "success");
      Assert (F.Console.Out_Text = "", "nothing");
      Put (Dir, "plain.md", "status: not frontmatter" & LF);
      Assert (Run (Env (F), Args ("get", "plain.md", "status")) = 0, "plain");
      Assert
        (F.Console.Out_Text = "", "a note with no frontmatter has no key");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Get_Of_An_Absent_Key_Prints_Nothing_And_Succeeds;

   procedure Get_Does_Not_Read_A_Key_Out_Of_The_Body
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "x.md", Note);
      Assert (Run (Env (F), Args ("get", "x.md", "status")) = 0, "success");
      Assert (F.Console.Out_Text = "TODO" & LF, "the frontmatter's");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Get_Does_Not_Read_A_Key_Out_Of_The_Body;

   procedure Get_Of_A_Missing_Or_Unsafe_Note_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "../secret.md", Note);
      Assert (Run (Env (F), Args ("get", "gone.md", "k")) = 1, "missing");
      Assert (Run (Env (F), Args ("get", "../x.md", "k")) = 1, "unsafe");
      Assert
        (Run (Env (F), Args ("get", "../secret.md", "title")) = 1,
         "outside the vault, though the file is there");
      Assert
        (F.Console.Err_Text =
         "synapse-frontmatter: no such note: gone.md" & LF &
         "synapse-frontmatter: no such note: ../x.md" & LF &
         "synapse-frontmatter: no such note: ../secret.md" & LF,
         "both messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Get_Of_A_Missing_Or_Unsafe_Note_Fails;

   procedure Frontmatter_Needs_A_Vault_And_A_Valid_Request
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Assert (Run (Env (F), Args ("get", "x.md", "k")) = 1, "no vault");
      Assert
        (F.Console.Err_Text = "synapse-frontmatter: no vault" & LF, "message");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("get", "x.md")) = 2, "usage error");
      Assert (F.Console.Err_Text = Vault_Usage.Frontmatter, "the usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Frontmatter_Needs_A_Vault_And_A_Valid_Request;

   procedure Help_Anywhere_In_The_Arguments_Prints_The_Usage
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("get", "x.md", "-h")) = 0, "late");
      Assert (Run (Env (F), Args ("--help")) = 0, "first");
      Assert
        (F.Console.Err_Text =
         Vault_Usage.Frontmatter & Vault_Usage.Frontmatter,
         "the usage each time");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Help_Anywhere_In_The_Arguments_Prints_The_Usage;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Frontmatter");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Parse_Takes_A_Path_And_A_Key_For_Get'Access,
         "Parse takes a path and a key for get");
      Register_Routine
        (T, Parse_Takes_A_Bare_Key_And_Value_For_Set'Access,
         "Parse takes a bare key and value for set");
      Register_Routine
        (T, Parse_Takes_A_Tag_Flag_With_Only_A_Path'Access,
         "Parse takes a tag flag with only a path");
      Register_Routine
        (T, Parse_Refuses_A_Tag_Flag_Together_With_A_Key_And_Value'Access,
         "Parse refuses a tag flag together with a key and value");
      Register_Routine
        (T, Parse_Refuses_What_Is_Incomplete_Or_Unknown'Access,
         "Parse refuses what is incomplete or unknown");
      Register_Routine
        (T, Get_Prints_A_Field_As_Written'Access,
         "Get prints a field as written");
      Register_Routine
        (T, Get_Of_An_Absent_Key_Prints_Nothing_And_Succeeds'Access,
         "Get of an absent key prints nothing and succeeds");
      Register_Routine
        (T, Get_Does_Not_Read_A_Key_Out_Of_The_Body'Access,
         "Get does not read a key out of the body");
      Register_Routine
        (T, Get_Of_A_Missing_Or_Unsafe_Note_Fails'Access,
         "Get of a missing or unsafe note fails");
      Register_Routine
        (T, Frontmatter_Needs_A_Vault_And_A_Valid_Request'Access,
         "Frontmatter needs a vault and a valid request");
      Register_Routine
        (T, Help_Anywhere_In_The_Arguments_Prints_The_Usage'Access,
         "Help anywhere in the arguments prints the usage");
   end Register_Tests;

end Synapse.Commands.Frontmatter.Tests;
