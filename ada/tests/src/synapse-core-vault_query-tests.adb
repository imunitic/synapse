with Ada.Containers;
with AUnit.Assertions;

package body Synapse.Core.Vault_Query.Tests is

   use AUnit.Assertions;
   use type Ada.Containers.Count_Type;
   use type JSON.Kind;

   package Port renames Synapse.Ports.Store;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  A store of a few notes that remembers every name it was asked to read:
   --  a test of the path-only short circuit needs to show a read did not
   --  happen and not only that its row is missing.
   type Recording_Store is limited new Port.Store with record
      Names  : Text_Lists.Vector;
      Bodies : Text_Lists.Vector;
      Reads  : Text_Lists.Vector;
   end record;

   overriding function Read
     (S : in out Recording_Store; Node : String) return Port.Maybe_Text;

   overriding function Write
     (S : in out Recording_Store; Node, Content : String)
      return Port.Write_Result;

   overriding function List
     (S : in out Recording_Store) return Text_Lists.Vector;

   overriding function Search
     (S : in out Recording_Store; Query : String)
      return Port.Hit_Vectors.Vector;

   overriding function Read
     (S : in out Recording_Store; Node : String) return Port.Maybe_Text
   is
   begin
      S.Reads.Append (To_Unbounded_String (Node));
      for I in 1 .. Natural (S.Names.Length) loop
         if To_String (S.Names (I)) = Node then
            return (Found => True, Text => S.Bodies (I));
         end if;
      end loop;
      return (Found => False);
   end Read;

   overriding function Write
     (S : in out Recording_Store; Node, Content : String)
      return Port.Write_Result
   is
   begin
      return (others => <>);
   end Write;

   overriding function List
     (S : in out Recording_Store) return Text_Lists.Vector is
     (S.Names);

   overriding function Search
     (S : in out Recording_Store; Query : String)
      return Port.Hit_Vectors.Vector
   is
   begin
      return Port.Hit_Vectors.Empty_Vector;
   end Search;

   procedure Put (S : in out Recording_Store; Name, Text : String) is
   begin
      S.Names.Append (To_Unbounded_String (Name));
      S.Bodies.Append (To_Unbounded_String (Text));
   end Put;

   function Parsed (Text : String) return JSON.Value is
      Got : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Got.Ok, "the filter is JSON: " & Text);
      return Got.Item;
   end Parsed;

   function Fields_Of (A, B : String := "") return Text_Lists.Vector is
      Result : Text_Lists.Vector;
   begin
      if A /= "" then
         Result.Append (To_Unbounded_String (A));
      end if;
      if B /= "" then
         Result.Append (To_Unbounded_String (B));
      end if;
      return Result;
   end Fields_Of;

   procedure Filters_By_Frontmatter_And_Projects_A_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S    : Recording_Store;
      Rows : Row_Vectors.Vector;
   begin
      Put
        (S, "a.md",
         "---" & LF & "status: TODO" & LF & "---" & LF & "body a" & LF);
      Put
        (S, "b.md",
         "---" & LF & "status: DONE" & LF & "---" & LF & "body b" & LF);
      Rows :=
        Query
          (S,
           Parsed ("{""=="": [{""var"": ""frontmatter.status""}, ""TODO""]}"),
           Fields_Of ("frontmatter.status"));
      Assert (Rows.Length = 1, "one match");
      Assert (To_String (Rows (1).Path) = "a.md", "a.md");
      Assert
        (JSON.As_String (Rows (1).Values (1)) = "TODO", "the projected field");
   end Filters_By_Frontmatter_And_Projects_A_Field;

   procedure An_Always_True_Filter_Returns_Every_Node_In_List_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S    : Recording_Store;
      Rows : Row_Vectors.Vector;
   begin
      Put (S, "a.md", "body" & LF);
      Put (S, "b.md", "body" & LF);
      Rows := Query (S, Parsed ("true"), Fields_Of);
      Assert (Rows.Length = 2, "both");
      Assert
        (To_String (Rows (1).Path) = "a.md"
         and then To_String (Rows (2).Path) = "b.md",
         "in list order");
      Assert (Rows (1).Values.Is_Empty, "no fields asked, none given");
   end An_Always_True_Filter_Returns_Every_Node_In_List_Order;

   procedure Content_And_Path_Are_Queryable_Not_Just_Frontmatter
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S    : Recording_Store;
      Rows : Row_Vectors.Vector;
   begin
      Put (S, "designs/x.md", "## Status" & LF & "Ready" & LF);
      Put (S, "tasks/y.md", "## Status" & LF & "Ready" & LF);
      Rows :=
        Query
          (S,
           Parsed
             ("{""and"": [{""glob"": [""designs/*"", {""var"": ""path""}]}," &
              " {""regexp"": [""Ready"", {""var"": ""content""}]}]}"),
           Fields_Of ("path"));
      Assert
        (Rows.Length = 1 and then To_String (Rows (1).Path) = "designs/x.md",
         "only the design that is ready");
      Assert
        (JSON.As_String (Rows (1).Values (1)) = "designs/x.md",
         "path is a field");
   end Content_And_Path_Are_Queryable_Not_Just_Frontmatter;

   procedure A_Tags_Flow_Sequence_Is_An_Array_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : Recording_Store;
   begin
      Put
        (S, "a.md",
         "---" & LF & "tags: [synapse, vault-infra]" & LF & "---" & LF &
         "body" & LF);
      Put
        (S, "b.md", "---" & LF & "tags:" & LF & "  - other" & LF & "---" & LF);
      Assert
        (Query
           (S, Parsed ("{""in"": [""synapse"", {""var"": ""tags""}]}"),
            Fields_Of)
           .Length =
         1,
         "a flow sequence");
      Assert
        (Query
           (S, Parsed ("{""in"": [""other"", {""var"": ""tags""}]}"),
            Fields_Of)
           .Length =
         1,
         "a block list too");
      Assert
        (Query
           (S,
            Parsed ("{""in"": [""other"", {""var"": ""frontmatter.tags""}]}"),
            Fields_Of)
           .Length =
         1,
         "and under frontmatter");
   end A_Tags_Flow_Sequence_Is_An_Array_Field;

   procedure A_Note_That_Fails_The_Filter_Contributes_No_Row
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : Recording_Store;
   begin
      Put (S, "a.md", "---" & LF & "status: TODO" & LF & "---" & LF);
      Assert
        (Query
           (S,
            Parsed ("{""=="": [{""var"": ""frontmatter.status""}, ""DONE""]}"),
            Fields_Of)
           .Is_Empty,
         "no row");
   end A_Note_That_Fails_The_Filter_Contributes_No_Row;

   procedure A_Missing_Field_Projects_As_Null_Not_An_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S    : Recording_Store;
      Rows : Row_Vectors.Vector;
   begin
      Put (S, "a.md", "---" & LF & "title: x" & LF & "---" & LF);
      Rows := Query (S, Parsed ("true"), Fields_Of ("frontmatter.missing"));
      Assert (Rows.Length = 1, "the row");
      Assert (JSON.Kind_Of (Rows (1).Values (1)) = JSON.JSON_Null, "null");
   end A_Missing_Field_Projects_As_Null_Not_An_Error;

   procedure An_Unknown_Operator_Means_No_Match_Not_A_Failure
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : Recording_Store;
   begin
      Put (S, "a.md", "body" & LF);
      Assert
        (Query (S, Parsed ("{""nonsense-operator"": []}"), Fields_Of).Is_Empty,
         "the row just does not match");
      Assert
        (not Path_Matches (Parsed ("{""nonsense-operator"": []}"), "a.md"),
         "and a path filter that cannot be evaluated does not match");
   end An_Unknown_Operator_Means_No_Match_Not_A_Failure;

   procedure A_Field_That_Cannot_Be_Evaluated_Projects_As_Null
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S    : Recording_Store;
      Rows : Row_Vectors.Vector;
   begin
      Put (S, "a.md", "body" & LF);
      Rows := Query (S, Parsed ("true"), Fields_Of ("content", "no.such"));
      Assert
        (JSON.As_String (Rows (1).Values (1)) = "body" & LF,
         "the whole text, when asked for");
      Assert (JSON.Kind_Of (Rows (1).Values (2)) = JSON.JSON_Null, "null");
   end A_Field_That_Cannot_Be_Evaluated_Projects_As_Null;

   procedure Path_Matches_Evaluates_A_Bare_Path_Filter
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Filter : constant JSON.Value :=
        Parsed ("{""glob"": [""designs/*"", {""var"": ""path""}]}");
   begin
      Assert (Path_Matches (Filter, "designs/x.md"), "matches");
      Assert (not Path_Matches (Filter, "tasks/y.md"), "does not");
   end Path_Matches_Evaluates_A_Bare_Path_Filter;

   procedure A_Failing_Path_Only_And_Clause_Skips_The_Read_Entirely
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S    : Recording_Store;
      Rows : Row_Vectors.Vector;
   begin
      Put (S, "designs/x.md", "## Status" & LF & "Ready" & LF);
      Put (S, "tasks/y.md", "## Status" & LF & "Ready" & LF);
      Rows :=
        Query
          (S,
           Parsed
             ("{""and"": [{""glob"": [""designs/*"", {""var"": ""path""}]}," &
              " {""regexp"": [""Ready"", {""var"": ""content""}]}]}"),
           Fields_Of ("path"));
      Assert (Rows.Length = 1, "one row");
      Assert
        (S.Reads.Length = 1 and then To_String (S.Reads (1)) = "designs/x.md",
         "tasks/y.md was never read, not just filtered out afterwards");
   end A_Failing_Path_Only_And_Clause_Skips_The_Read_Entirely;

   procedure A_Bare_Path_Only_Filter_With_No_And_Still_Skips_The_Read
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S    : Recording_Store;
      Rows : Row_Vectors.Vector;
   begin
      Put (S, "designs/x.md", "## Status" & LF & "Ready" & LF);
      Put (S, "tasks/y.md", "## Status" & LF & "Ready" & LF);
      Rows :=
        Query
          (S, Parsed ("{""glob"": [""designs/*"", {""var"": ""path""}]}"),
           Fields_Of ("path"));
      Assert (Rows.Length = 1, "one row");
      Assert
        (S.Reads.Length = 1 and then To_String (S.Reads (1)) = "designs/x.md",
         "the same saving with no wrapper");
   end A_Bare_Path_Only_Filter_With_No_And_Still_Skips_The_Read;

   procedure A_Filter_With_No_Path_Only_Clause_Reads_Every_Candidate
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S    : Recording_Store;
      Rows : Row_Vectors.Vector;
   begin
      Put (S, "a.md", "---" & LF & "status: TODO" & LF & "---" & LF);
      Put (S, "b.md", "---" & LF & "status: DONE" & LF & "---" & LF);
      Rows :=
        Query
          (S,
           Parsed ("{""=="": [{""var"": ""frontmatter.status""}, ""TODO""]}"),
           Fields_Of);
      Assert (Rows.Length = 1, "one row");
      Assert (S.Reads.Length = 2, "both were read");
   end A_Filter_With_No_Path_Only_Clause_Reads_Every_Candidate;

   procedure An_And_Clause_Mixing_Path_With_Content_Is_Not_Path_Only
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S    : Recording_Store;
      Rows : Row_Vectors.Vector;
   begin
      Put (S, "a.md", "body" & LF);
      Rows :=
        Query
          (S,
           Parsed
             ("{""and"": [{""=="": [{""var"": ""path""}," &
              " {""var"": ""content""}]}]}"),
           Fields_Of);
      Assert (Rows.Is_Empty, "path and content differ");
      Assert (S.Reads.Length = 1, "and the note was read to find out");
   end An_And_Clause_Mixing_Path_With_Content_Is_Not_Path_Only;

   procedure An_And_With_One_Clause_That_Is_Not_An_Array_Is_Handled
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : Recording_Store;
   begin
      Put (S, "designs/x.md", "x" & LF);
      Put (S, "tasks/y.md", "x" & LF);
      Assert
        (Query
           (S,
            Parsed
              ("{""and"": {""glob"": [""designs/*"", {""var"": ""path""}]}}"),
            Fields_Of)
           .Length =
         1,
         "a single clause given bare");
   end An_And_With_One_Clause_That_Is_Not_An_Array_Is_Handled;

   procedure A_Var_Of_Anything_But_Path_Is_Not_Path_Only
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : Recording_Store;
   begin
      Put (S, "a.md", "---" & LF & "k: v" & LF & "---" & LF);
      Assert
        (Query
           (S, Parsed ("{""and"": [{""var"": ""frontmatter.k""}]}"), Fields_Of)
           .Length =
         1
         and then S.Reads.Length = 1,
         "read, because it needs the note");
      S.Reads.Clear;
      Assert
        (Query
           (S, Parsed ("{""and"": [{""var"": [""path"", ""d""]}]}"), Fields_Of)
           .Length =
         1
         and then S.Reads.Length = 1,
         "the array form of var is not treated as path only");
   end A_Var_Of_Anything_But_Path_Is_Not_Path_Only;

   procedure Note_Data_Has_The_Four_Fields (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Data : constant JSON.Value :=
        Note_Data
          ("a.md", "---" & LF & "tags: [x]" & LF & "---" & LF & "body" & LF);
   begin
      Assert
        (JSON.Has_Member (Data, "path")
         and then JSON.Has_Member (Data, "content")
         and then JSON.Has_Member (Data, "frontmatter")
         and then JSON.Has_Member (Data, "tags"),
         "path, content, frontmatter, tags");
      Assert
        (JSON.Length
           (JSON.Member_Value (Note_Data ("b.md", "no fm"), "tags")) =
         0,
         "tags are an empty list when the note has none");
   end Note_Data_Has_The_Four_Fields;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Vault_Query");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Filters_By_Frontmatter_And_Projects_A_Field'Access,
         "Filters by frontmatter and projects a field");
      Register_Routine
        (T, An_Always_True_Filter_Returns_Every_Node_In_List_Order'Access,
         "An always true filter returns every node in list order");
      Register_Routine
        (T, Content_And_Path_Are_Queryable_Not_Just_Frontmatter'Access,
         "Content and path are queryable, not just frontmatter");
      Register_Routine
        (T, A_Tags_Flow_Sequence_Is_An_Array_Field'Access,
         "Tags are an array field, flow or block");
      Register_Routine
        (T, A_Note_That_Fails_The_Filter_Contributes_No_Row'Access,
         "A note that fails the filter contributes no row");
      Register_Routine
        (T, A_Missing_Field_Projects_As_Null_Not_An_Error'Access,
         "A missing field projects as null, not an error");
      Register_Routine
        (T, An_Unknown_Operator_Means_No_Match_Not_A_Failure'Access,
         "An unknown operator means no match, not a failure");
      Register_Routine
        (T, A_Field_That_Cannot_Be_Evaluated_Projects_As_Null'Access,
         "A field that cannot be evaluated projects as null");
      Register_Routine
        (T, Path_Matches_Evaluates_A_Bare_Path_Filter'Access,
         "Path_Matches evaluates a bare path filter");
      Register_Routine
        (T, A_Failing_Path_Only_And_Clause_Skips_The_Read_Entirely'Access,
         "A failing path-only and clause skips the read entirely");
      Register_Routine
        (T, A_Bare_Path_Only_Filter_With_No_And_Still_Skips_The_Read'Access,
         "A bare path-only filter with no and still skips the read");
      Register_Routine
        (T, A_Filter_With_No_Path_Only_Clause_Reads_Every_Candidate'Access,
         "A filter with no path-only clause reads every candidate");
      Register_Routine
        (T, An_And_Clause_Mixing_Path_With_Content_Is_Not_Path_Only'Access,
         "An and clause mixing path with content is not path only");
      Register_Routine
        (T, An_And_With_One_Clause_That_Is_Not_An_Array_Is_Handled'Access,
         "An and with one clause that is not an array is handled");
      Register_Routine
        (T, A_Var_Of_Anything_But_Path_Is_Not_Path_Only'Access,
         "A var of anything but path is not path only");
      Register_Routine
        (T, Note_Data_Has_The_Four_Fields'Access,
         "Note data has the four fields");
   end Register_Tests;

end Synapse.Core.Vault_Query.Tests;
