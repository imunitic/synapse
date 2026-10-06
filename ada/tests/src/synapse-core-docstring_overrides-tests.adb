with Ada.Strings.Unbounded;

with AUnit.Assertions;

package body Synapse.Core.Docstring_Overrides.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Joined (V : Text_Lists.Vector) return String is
      Result : String (1 .. 4_096);
      Last   : Natural := 0;
   begin
      for Item of V loop
         declare
            S : constant String :=
              Ada.Strings.Unbounded.To_String (Item) & ";";
         begin
            Result (Last + 1 .. Last + S'Length) := S;
            Last                                 := Last + S'Length;
         end;
      end loop;
      return Result (1 .. Last);
   end Joined;

   function Named (Source : String) return String is
      Got : constant Maybe_Text := Single_Node_Type (Source);
   begin
      return
        (if Got.Found then Ada.Strings.Unbounded.To_String (Got.Text)
         else "<none>");
   end Named;

   procedure The_Node_Type_Is_Read_With_Or_Without_A_Capture
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Named ("(line_comment) @comment" & LF) = "line_comment",
         "with a capture");
      Assert (Named ("(comment)") = "comment", "without");
      Assert (Named ("(comment@x)") = "comment", "an @ ends it");
      Assert (Named ("   (a b)") = "a", "whitespace ends it");
      Assert (Named ("(abc") = "abc", "no closing parenthesis");
   end The_Node_Type_Is_Read_With_Or_Without_A_Capture;

   procedure Content_With_No_Node_Type_Names_None (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Named ("") = "<none>", "empty");
      Assert (Named ("comment") = "<none>", "no parenthesis");
      Assert (Named ("()") = "<none>", "nothing inside");
      Assert (Named ("( x)") = "<none>", "whitespace first");
      Assert (Named ("(@x)") = "<none>", "a capture first");
   end Content_With_No_Node_Type_Names_None;

   procedure A_Comment_Type_Is_The_Default_Unless_The_File_Names_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Comment_Type ("") = Default_Comment_Type, "no file");
      Assert
        (Comment_Type ("(line_comment) @comment" & LF) = "line_comment",
         "named");
      Assert
        (Comment_Type ("; nothing here") = "comment",
         "a file with no node type falls back, not to nothing");
   end A_Comment_Type_Is_The_Default_Unless_The_File_Names_One;

   procedure Declaration_Kinds_Are_One_Node_Type_Per_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Joined (Declaration_Kinds ("")) = "", "none");
      Assert
        (Joined
           (Declaration_Kinds
              ("(variable_declaration) @declaration" & LF & LF &
               "(return_statement)" & LF)) =
         "variable_declaration;return_statement;",
         "two, the empty line skipped");
      Assert
        (Joined (Declaration_Kinds ("no parens" & LF & "(a)")) = "a;",
         "a line with none is skipped, and a last line needs no line feed");
      Assert
        (Joined (Declaration_Kinds ("(a)" & Character'Val (13) & LF & "(b)")) =
         "a;b;",
         "a carriage return does not end up in a name");
   end Declaration_Kinds_Are_One_Node_Type_Per_Line;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Docstring_Overrides");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Node_Type_Is_Read_With_Or_Without_A_Capture'Access,
         "The node type is read with or without a capture");
      Register_Routine
        (T, Content_With_No_Node_Type_Names_None'Access,
         "Content with no node type names none");
      Register_Routine
        (T, A_Comment_Type_Is_The_Default_Unless_The_File_Names_One'Access,
         "A comment type is the default unless the file names one");
      Register_Routine
        (T, Declaration_Kinds_Are_One_Node_Type_Per_Line'Access,
         "Declaration kinds are one node type per line");
   end Register_Tests;

end Synapse.Core.Docstring_Overrides.Tests;
