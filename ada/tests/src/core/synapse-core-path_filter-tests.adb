with AUnit.Assertions;

package body Synapse.Core.Path_Filter.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Rule (Text : String) return JSON.Value is
      Quoted : String := Text;
   begin
      for C of Quoted loop
         if C = Character'Val (39) then
            C := '"';
         end if;
      end loop;
      declare
         Parsed : constant JSON.Parse_Result := JSON.Parse (Quoted);
      begin
         Assert (Parsed.Ok, "the rule parses");
         return Parsed.Item;
      end;
   end Rule;

   procedure Rules_Over_The_Path_Match_Or_Not (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Glob : constant JSON.Value :=
        Rule ("{'glob': ['designs/*', {'var': 'path'}]}");
   begin
      Assert (Matches (Glob, "designs/x.md"), "a path under designs");
      Assert (not Matches (Glob, "tasks/x.md"), "a path elsewhere");
      Assert (Matches (Rule ("{'==': [{'var': 'path'}, 'a.md']}"), "a.md"),
              "equality");
      Assert (Matches (Rule ("{'starts_with': [{'var': 'path'}, 'tasks/']}"),
                       "tasks/x.md"), "a prefix");
      Assert (Matches (Rule ("true"), "x"), "a constant true");
      Assert (not Matches (Rule ("false"), "x"), "a constant false");
      Assert (not Matches (Rule ("null"), "x"), "null is falsy");
      Assert (not Matches (Rule ("0"), "x"), "zero is falsy");
      Assert (Matches (Rule ("'text'"), "x"), "a non-empty string is truthy");
   end Rules_Over_The_Path_Match_Or_Not;

   procedure A_Rule_That_Raises_Does_Not_Match (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Matches (Rule ("{'no_such_operator': 1}"), "x"),
              "an unknown operator");
      Assert (not Matches (Rule ("{'==': [1]}"), "x"), "too few arguments");
      Assert (not Matches (Rule ("{'!': {'also_unknown': 1}}"), "x"),
              "an unknown operator below another");
   end A_Rule_That_Raises_Does_Not_Match;

   procedure Only_The_Path_Is_Visible (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Matches (Rule ("{'var': 'content'}"), "x"),
              "no content to read");
      Assert (not Matches (Rule ("{'var': 'frontmatter.title'}"), "x"),
              "no frontmatter either");
   end Only_The_Path_Is_Visible;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Path_Filter");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Rules_Over_The_Path_Match_Or_Not'Access,
         "Rules over the path match or not");
      Register_Routine
        (T, A_Rule_That_Raises_Does_Not_Match'Access,
         "A rule that raises does not match");
      Register_Routine
        (T, Only_The_Path_Is_Visible'Access, "Only the path is visible");
   end Register_Tests;

end Synapse.Core.Path_Filter.Tests;
