with Ada.Strings.Unbounded;

with AUnit.Assertions;
with Synapse.Adapters.Fake_Variables;
with Synapse.Ports.Variables;

package body Synapse.Core.Conf.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Got (Text, Key : String) return String is
      Found : constant Maybe_Text := Get (Text, Key);
   begin
      return
        (if Found.Found then "<" & To_String (Found.Value) & ">" else "none");
   end Got;

   procedure Reads_The_Shipped_Template (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text : constant String :=
        "# Copy this to ~/.claude/synapse.conf" & LF &
        "SYNAPSE_VAULT_DIR=""/Users/x/Vault/Claude""" & LF;
   begin
      Assert
        (Got (Text, "SYNAPSE_VAULT_DIR") = "</Users/x/Vault/Claude>",
         "a quoted value");
      Assert (Got (Text, "SOMETHING_ELSE") = "none", "another key");
   end Reads_The_Shipped_Template;

   procedure Quoting_Comments_And_Export_Read_Alike
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Got ("K=/v" & LF, "K") = "</v>", "bare");
      Assert (Got ("K='/v'" & LF, "K") = "</v>", "single quotes");
      Assert (Got ("export K=""/v""" & LF, "K") = "</v>", "export");
      Assert (Got ("export   K=/v" & LF, "K") = "</v>", "export and blanks");
      Assert (Got ("K=/v  # trailing" & LF, "K") = "</v>", "a comment");
      Assert (Got ("K=" & LF, "K") = "<>", "empty");
      Assert
        (Got ("K=""/My Vault""" & LF, "K") = "</My Vault>",
         "a space needs quotes and keeps them");
      Assert (Got ("K=/a b" & LF, "K") = "</a>", "an unquoted value stops");
      Assert (Got ("K=""a # b""" & LF, "K") = "<a # b>", "a # inside quotes");
      Assert (Got ("K=/v" & Character'Val (13) & LF, "K") = "</v>", "CRLF");
      Assert (Got ("  K=/v" & LF, "K") = "</v>", "indented");
      Assert (Got ("K = /v" & LF, "K") = "none", "blanks around = are not");
      Assert (Got ("", "K") = "none", "empty text");
      Assert (Got ("K=""x", "K") = "<""x>", "an unterminated quote");
      Assert (Got ("K=""""", "K") = "<>", "two quotes");
      Assert (Got ("K=""", "K") = "<"">", "one quote");
   end Quoting_Comments_And_Export_Read_Alike;

   procedure Keys_Are_Matched_Whole_And_The_Last_Wins
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Got ("K_OLD=/old" & LF, "K") = "none", "a longer key");
      Assert
        (Got ("K=/first" & LF & "K=/second" & LF, "K") = "</second>",
         "the last assignment wins, as sourcing would");
      Assert (Got ("# K=/nope" & LF, "K") = "none", "commented out");
      Assert
        (Got ("K=/a" & LF & "# K=/b" & LF, "K") = "</a>",
         "a later comment does not override");
   end Keys_Are_Matched_Whole_And_The_Last_Wins;

   function Expanded
     (Raw : String; Vars : Ports.Variables.Variables'Class) return String is
     (Expand (Raw, Vars));

   procedure Any_Variable_Expands (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      V : Adapters.Fake_Variables.Fake_Variables;
   begin
      V.Set ("CASA", "/casa");
      V.Set ("XDG_DATA_HOME", "/xdg");
      V.Set ("HOME", "/h");
      Assert (Expanded ("$CASA/vault", V) = "/casa/vault", "bare name");
      Assert (Expanded ("${CASA}/vault", V) = "/casa/vault", "braced");
      Assert
        (Expanded ("$XDG_DATA_HOME/vault", V) = "/xdg/vault", "underscores");
      Assert (Expanded ("~/Vault", V) = "/h/Vault", "tilde");
      Assert (Expanded ("~", V) = "/h", "tilde alone");
      Assert
        (Expanded ("$HOME/a/$CASA", V) = "/h/a//casa",
         "several, with the name length right");
      Assert (Expanded ("$CASAx", V) = "", "the whole name is the name");
      Assert (Expanded ("${CASA}x", V) = "/casax", "braces end it");
      Assert (Expanded ("a$CASA$CASA", V) = "a/casa/casa", "adjacent");
      Assert (Expanded ("", V) = "", "empty");
   end Any_Variable_Expands;

   procedure An_Unset_Variable_Expands_To_Nothing (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : Adapters.Fake_Variables.Fake_Variables;
   begin
      Assert (Expanded ("$CASA/vault", V) = "/vault", "as a shell does");
      V.Set ("EMPTY", "");
      Assert (Expanded ("a${EMPTY}b", V) = "ab", "an empty one too");
   end An_Unset_Variable_Expands_To_Nothing;

   procedure Unsupported_Forms_Stay_Literal (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      V : Adapters.Fake_Variables.Fake_Variables;

      procedure Same (Text : String) is
      begin
         Assert (Expanded (Text, V) = Text, "literal: " & Text);
      end Same;
   begin
      V.Set ("HOME", "/h");
      V.Set ("V", "x");
      Same ("/a/~/b");
      Same ("~user/x");
      Same ("/a$/b");
      Same ("/a$1/b");
      Same ("trailing$");
      Same ("${V:-default}");
      Same ("${unterminated");
      Same ("C:\dir");
      Same ("${}");
      Same ("${1x}");
      Assert (Expanded ("\$V", V) = "$V", "an escaped dollar");
      --  The second backslash escapes the dollar, so nothing expands.
      Assert (Expanded ("\\$V", V) = "\$V", "an escape after a backslash");
   end Unsupported_Forms_Stay_Literal;

   procedure A_Source_That_Knows_Nothing_Drops_Every_Reference
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      None : Ports.Variables.No_Variables;
   begin
      Assert (Expand ("$HOME/x", None) = "/x", "no home");
      Assert (Expand ("~/x", None) = "/x", "no home for a tilde either");
   end A_Source_That_Knows_Nothing_Drops_Every_Reference;

   procedure A_Value_Is_Read_Then_Expanded (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      V : Adapters.Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", "/Users/x");
      declare
         Found : constant Maybe_Text :=
           Value
             ("SYNAPSE_VAULT_DIR=""$HOME/Vault/YourVault""" & LF,
              "SYNAPSE_VAULT_DIR", V);
      begin
         Assert
           (Found.Found
            and then To_String (Found.Value) = "/Users/x/Vault/YourVault",
            "the template's shape");
      end;
      Assert (not Value ("A=1", "B", V).Found, "no such key");
   end A_Value_Is_Read_Then_Expanded;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Conf");
   end Name;

   procedure Set_Replaces_The_Last_Assignment_In_Place
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        "# one" & LF & "K=old" & LF & "  export K=""mid"" # note" & LF &
        "OTHER=x" & LF;
   begin
      Assert
        (Set (Text, "K", "new") =
         "# one" & LF & "K=old" & LF & "  export K=new # note" & LF &
         "OTHER=x" & LF,
         "the last one is replaced and the rest is as it was: " &
         Set (Text, "K", "new"));
      Assert (Got (Set (Text, "K", "new"), "K") = "<new>", "and it is read");
   end Set_Replaces_The_Last_Assignment_In_Place;

   procedure Set_Keeps_What_Follows_The_Value (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Set ("K=/old   # why" & LF, "K", "/new") = "K=/new   # why" & LF,
         "a comment after an unquoted value");
      Assert
        (Set ("K=""a b"" # why" & LF, "K", "c") = "K=c # why" & LF,
         "a comment after a quoted value");
      Assert
        (Set ("K='x y'" & LF, "K", "z z") = "K=""z z""" & LF,
         "a quoted value is replaced whole");
      Assert (Set ("K=" & LF, "K", "v") = "K=v" & LF, "an empty value");
   end Set_Keeps_What_Follows_The_Value;

   procedure Set_Adds_A_Key_That_Is_Not_There (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Set ("", "K", "v") = "K=v" & LF, "into nothing");
      Assert
        (Set ("A=1", "K", "v") = "A=1" & LF & "K=v" & LF,
         "after a last line with no line feed");
      Assert
        (Set ("A=1" & LF & "# K=old" & LF & "KK=2" & LF, "K", "v") =
         "A=1" & LF & "# K=old" & LF & "KK=2" & LF & "K=v" & LF,
         "a comment and a longer key are not the key");
   end Set_Adds_A_Key_That_Is_Not_There;

   procedure Set_Keeps_A_Carriage_Return_And_Line_Ends
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      CR : constant Character := Character'Val (13);
   begin
      Assert
        (Set ("K=old" & CR & LF & "A=1" & CR & LF, "K", "new") =
         "K=new" & CR & LF & "A=1" & CR & LF,
         "a file with carriage returns keeps them");
   end Set_Keeps_A_Carriage_Return_And_Line_Ends;

   procedure A_Value_Is_Written_So_That_It_Reads_Back
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Round (Value : String) is
      begin
         Assert
           (Got (Set ("", "K", Value), "K") = "<" & Value & ">",
            "reads back: " & Value);
      end Round;
   begin
      Round ("/plain/path");
      Round ("with a blank");
      Round ("has # a hash");
      Round ("it's");
      Round ("say ""hi""");
      Round ("");
      Round ("$HOME/vault");
      Assert (Set ("", "K", "a b") = "K=""a b""" & LF, "double quotes");
      Assert (Set ("", "K", "$HOME/v") = "K=$HOME/v" & LF, "left to expand");
   end A_Value_Is_Written_So_That_It_Reads_Back;

   procedure A_Value_That_Has_No_Written_Form_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Refused : Boolean := False;
   begin
      begin
         declare
            Unused : constant String := Set ("", "K", "a" & LF & "b");
         begin
            null;
         end;
      exception
         when Unrepresentable =>
            Refused := True;
      end;
      Assert (Refused, "a line feed");
      Refused := False;
      begin
         declare
            Unused : constant String := Set ("", "K", "it's ""x""");
         begin
            null;
         end;
      exception
         when Unrepresentable =>
            Refused := True;
      end;
      Assert (Refused, "both kinds of quote");
   end A_Value_That_Has_No_Written_Form_Is_Refused;

   procedure Unset_Removes_Every_Assignment_And_Nothing_Else
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        "# keep" & LF & "K=1" & LF & "KK=2" & LF & "export K=3" & LF &
        "# K=4" & LF & "last=5";
   begin
      Assert
        (Unset (Text, "K") = "# keep" & LF & "KK=2" & LF & "# K=4" & LF &
         "last=5",
         "only the assignments of K go: " & Unset (Text, "K"));
      Assert (Unset ("A=1", "K") = "A=1", "a key that is not there");
      Assert (Got (Unset (Text, "K"), "K") = "none", "and it reads as unset");
   end Unset_Removes_Every_Assignment_And_Nothing_Else;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Set_Replaces_The_Last_Assignment_In_Place'Access,
         "Set replaces the last assignment in place");
      Register_Routine
        (T, Set_Keeps_What_Follows_The_Value'Access,
         "Set keeps what follows the value");
      Register_Routine
        (T, Set_Adds_A_Key_That_Is_Not_There'Access,
         "Set adds a key that is not there");
      Register_Routine
        (T, Set_Keeps_A_Carriage_Return_And_Line_Ends'Access,
         "Set keeps a carriage return and the line ends");
      Register_Routine
        (T, A_Value_Is_Written_So_That_It_Reads_Back'Access,
         "A value is written so that it reads back");
      Register_Routine
        (T, A_Value_That_Has_No_Written_Form_Is_Refused'Access,
         "A value that has no written form is refused");
      Register_Routine
        (T, Unset_Removes_Every_Assignment_And_Nothing_Else'Access,
         "Unset removes every assignment and nothing else");
      Register_Routine
        (T, Reads_The_Shipped_Template'Access, "Reads the shipped template");
      Register_Routine
        (T, Quoting_Comments_And_Export_Read_Alike'Access,
         "Quoting, comments and export read alike");
      Register_Routine
        (T, Keys_Are_Matched_Whole_And_The_Last_Wins'Access,
         "Keys are matched whole and the last wins");
      Register_Routine
        (T, Any_Variable_Expands'Access, "Any variable expands");
      Register_Routine
        (T, An_Unset_Variable_Expands_To_Nothing'Access,
         "An unset variable expands to nothing");
      Register_Routine
        (T, Unsupported_Forms_Stay_Literal'Access,
         "Unsupported forms stay literal");
      Register_Routine
        (T, A_Source_That_Knows_Nothing_Drops_Every_Reference'Access,
         "A source that knows nothing drops every reference");
      Register_Routine
        (T, A_Value_Is_Read_Then_Expanded'Access,
         "A value is read then expanded");
   end Register_Tests;

end Synapse.Core.Conf.Tests;
