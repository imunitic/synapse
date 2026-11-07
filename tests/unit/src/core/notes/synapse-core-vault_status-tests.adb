with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Adapters.Fake_Store;
with Synapse.Core.JSON;

package body Synapse.Core.Vault_Status.Tests is

   use AUnit.Assertions;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Design (Id, Title, Status, Rest : String) return String is
     ("---" & LF & "title: """ & Title & """" & LF
      & (if Id = "" then "" else "note_id: " & Id & LF) & "---" & LF
      & "# " & Title & LF & LF & "## Status" & LF & Status & LF & LF & Rest);

   function Task_Note (Id, Title, Status, Checklist : String) return String is
     ("---" & LF & "title: """ & Title & """" & LF & "task_id: " & Id & LF
      & "status: " & Status & LF & "---" & LF & "# " & Title & LF & LF
      & Checklist);

   Open_Question : constant String :=
     "## Open Questions" & LF & "- What now?" & LF;

   procedure Fill (S : in out Synapse.Adapters.Fake_Store.Fake_Store) is
   begin
      S.Nodes.Include
        ("designs/p/Talk.md", Design ("p-1", "Talk", "Discussing", ""));
      S.Nodes.Include
        ("designs/p/No id.md", Design ("", "No id", "Discussing", ""));
      S.Nodes.Include
        ("designs/p/Plain.md", Design ("p-2", "Plain", "Ready", ""));
      S.Nodes.Include
        ("designs/p/Asks.md",
         Design ("p-3", "Asks", "Ready", Open_Question));
      S.Nodes.Include
        ("designs/p/Shipped.md",
         Design
           ("p-4", "Shipped", "Ready",
            "> Compiled task: [[Done task]]" & LF & Open_Question));
      S.Nodes.Include
        ("designs/p/Going.md",
         Design
           ("p-5", "Going", "Ready",
            "> Compiled task: [[Going task|alias]]" & LF & Open_Question));
      S.Nodes.Include
        ("designs/p/Broken.md",
         Design
           ("p-6", "Broken", "Ready",
            "> Compiled task: [[Not there]]" & LF & Open_Question));
      S.Nodes.Include
        ("designs/p/Settled.md",
         Design
           ("p-7", "Settled", "Ready",
            "> Compiled task: [[Done task]]" & LF & "## Open Questions" & LF));
      S.Nodes.Include
        ("inbox/Elsewhere.md", Design ("x-1", "Elsewhere", "Discussing", ""));
      S.Nodes.Include
        ("tasks/p/Done task.md",
         Task_Note ("p-10", "Done task", "DONE", "- [x] all" & LF));
      S.Nodes.Include
        ("tasks/p/Going task.md",
         Task_Note
           ("p-11", "Going task", "IN-PROGRESS",
            "- [x] one" & LF & "- [ ] two" & LF & "  - [ ] nested" & LF));
      S.Nodes.Include
        ("tasks/p/Todo task.md",
         Task_Note ("p-12", "Todo task", "TODO", "- [x] only" & LF));
      S.Nodes.Include
        ("tasks/p/Review task.md",
         Task_Note ("p-13", "A ""quoted"" review", "REVIEW", "- [x] x" & LF));
   end Fill;

   function Titles (Items : Item_Vectors.Vector) return String is
      Text : Unbounded_String;
   begin
      for Entry_Of of Items loop
         Append (Text, To_String (Entry_Of.Title) & ";");
      end loop;
      return To_String (Text);
   end Titles;

   procedure Compiled_Tasks_And_Unchecked_Items_Are_Read_From_The_Text
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Compiled_Task ("x" & LF & "> Compiled task: [[Some task]]" & LF) =
         "Some task",
         "the link's target");
      Assert
        (Compiled_Task ("Compiled task: [[Some task|shown]]") = "Some task"
         and then Compiled_Task ("Compiled task: [[Some task#part]]") =
                  "Some task"
         and then Compiled_Task ("Compiled task: [[ Spaced ]]") = "Spaced",
         "an alias or a heading is not part of the title");
      Assert
        (Compiled_Task ("no such line [[Other]]") = ""
         and then Compiled_Task ("Compiled task: none") = ""
         and then Compiled_Task ("Compiled task: [[open") = "",
         "nothing without a link");
      Assert
        (Unchecked_Count
           ("- [x] a" & LF & "- [ ] b" & LF & "   - [ ] c" & LF
            & "* [ ] d" & LF & "text - [ ] e" & LF & "- [ ]") = 3,
         "list items that are open, indented or at the end, and no others");
      Assert (Unchecked_Count ("") = 0, "no text");
   end Compiled_Tasks_And_Unchecked_Items_Are_Read_From_The_Text;

   procedure Every_Category_Finds_Its_Notes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : Synapse.Adapters.Fake_Store.Fake_Store;
   begin
      Fill (S);
      declare
         Found : constant Report := Build (S);
      begin
         Assert
           (Titles (Found (Discussing)) = "No id;Talk;",
            "discussing, and none from outside designs/: "
            & Titles (Found (Discussing)));
         Assert
           (Titles (Found (Ready_Uncompiled)) = "Asks;Plain;",
            "ready with no compiled task, whether or not it has open "
            & "questions, and not one that has a task: "
            & Titles (Found (Ready_Uncompiled)));
         Assert
           (Titles (Found (Open_Questions)) = "Asks;Broken;Going;",
            "open questions, without the one whose task is done, or the "
            & "one with none: " & Titles (Found (Open_Questions)));
         Assert
           (Titles (Found (In_Progress)) = "Going task;Todo task;",
            "tasks that are not finished or in review: "
            & Titles (Found (In_Progress)));
         Assert
           (Titles (Found (Awaiting_Review)) = "A ""quoted"" review;",
            "tasks in review");
         Assert (not Is_Clear (Found), "something is outstanding");
      end;
   end Every_Category_Finds_Its_Notes;

   procedure Items_Carry_What_Their_Category_Needs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : Synapse.Adapters.Fake_Store.Fake_Store;
   begin
      Fill (S);
      declare
         Found : constant Report := Build (S);
      begin
         Assert
           (To_String (Found (Discussing) (1).Id) = ""
            and then To_String (Found (Discussing) (2).Id) = "p-1"
            and then To_String (Found (Discussing) (2).Path) =
                     "designs/p/Talk.md",
            "an id when the note has one, and its path");
         Assert
           (To_String (Found (Open_Questions) (1).Compiled) = ""
            and then To_String (Found (Open_Questions) (2).Compiled) =
                     "Not there"
            and then To_String (Found (Open_Questions) (3).Compiled) =
                     "Going task",
            "the compiled task of an open question, by title");
         Assert
           (Found (In_Progress) (1).Unchecked = 2
            and then Found (In_Progress) (2).Unchecked = 0,
            "unchecked items, a fully checked list counting 0");
      end;
   end Items_Carry_What_Their_Category_Needs;

   procedure The_Text_Leaves_Out_Empty_Sections_And_Says_When_Clear
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S     : Synapse.Adapters.Fake_Store.Fake_Store;
      Clear : Synapse.Adapters.Fake_Store.Fake_Store;
      Dash  : constant String :=
        Character'Val (16#E2#) & Character'Val (16#80#)
        & Character'Val (16#94#);
   begin
      Fill (S);
      Assert
        (To_Text (Build (S)) =
         "## Discussing" & LF & "- No id" & LF & "- [p-1] Talk" & LF & LF
         & "## Ready, not yet compiled" & LF & "- [p-3] Asks" & LF
         & "- [p-2] Plain" & LF & LF
         & "## Open questions" & LF
         & "- [p-3] Asks " & Dash & " not compiled" & LF
         & "- [p-6] Broken " & Dash & " Not there" & LF
         & "- [p-5] Going " & Dash & " Going task" & LF & LF
         & "## In progress (unchecked items)" & LF
         & "- [p-11] Going task (2 unchecked)" & LF
         & "- [p-12] Todo task (0 unchecked)" & LF & LF
         & "## Awaiting review" & LF & "- [p-13] A ""quoted"" review" & LF,
         "a section for each category that has items, in order");
      Assert
        (To_Text (Build (Clear)) = "Vault is clear -- nothing outstanding." & LF
         and then Is_Clear (Build (Clear)),
         "one line when there is nothing");
   end The_Text_Leaves_Out_Empty_Sections_And_Says_When_Clear;

   procedure The_Json_Has_Every_Category_And_The_Paths
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S      : Synapse.Adapters.Fake_Store.Fake_Store;
      Empty  : Synapse.Adapters.Fake_Store.Fake_Store;
   begin
      Fill (S);
      declare
         Text   : constant String := To_JSON (Build (S), "/my/vault");
         Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
      begin
         Assert (Parsed.Ok, "it is JSON: " & Text);
         Assert
           (JSON.As_String (JSON.Member_Value (Parsed.Item, "format")) =
            "synapse-status/v1"
            and then JSON.As_String (JSON.Member_Value (Parsed.Item, "vault"))
                     = "/my/vault"
            and then not JSON.As_Boolean
                           (JSON.Member_Value (Parsed.Item, "clear")),
            "format, vault and whether it is clear");
         declare
            Categories : constant JSON.Value :=
              JSON.Member_Value (Parsed.Item, "categories");
         begin
            Assert (JSON.Length (Categories) = 5, "all five categories");
            Assert
              (JSON.As_String
                 (JSON.Member_Value (JSON.Element (Categories, 3), "key")) =
               "open_questions",
               "in order");
         end;
      end;
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (To_JSON (Build (Empty), "/v"));
      begin
         Assert
           (Parsed.Ok
            and then JSON.As_Boolean (JSON.Member_Value (Parsed.Item, "clear"))
            and then JSON.Length
                       (JSON.Member_Value (Parsed.Item, "categories")) = 5,
            "a clear vault still has every category, empty");
      end;
      Assert
        (Ada.Strings.Fixed.Index (To_JSON (Build (S), "/v"), """compiled_task"":""Going task""") > 0
         and then Ada.Strings.Fixed.Index (To_JSON (Build (S), "/v"), """unchecked"":2") > 0
         and then Ada.Strings.Fixed.Index
                    (To_JSON (Build (S), "/v"),
                     """path"":""designs/p/Talk.md"",""id"":""p-1""") > 0
         and then Ada.Strings.Fixed.Index
                    (To_JSON (Build (S), "/v"), """id"":null") > 0,
         "the compiled task, the count, the path and a missing id as null");
   end The_Json_Has_Every_Category_And_The_Paths;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Vault_Status");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Compiled_Tasks_And_Unchecked_Items_Are_Read_From_The_Text'Access,
         "Compiled tasks and unchecked items are read from the text");
      Register_Routine
        (T, Every_Category_Finds_Its_Notes'Access,
         "Every category finds its notes");
      Register_Routine
        (T, Items_Carry_What_Their_Category_Needs'Access,
         "Items carry what their category needs");
      Register_Routine
        (T, The_Text_Leaves_Out_Empty_Sections_And_Says_When_Clear'Access,
         "The text leaves out empty sections and says when clear");
      Register_Routine
        (T, The_Json_Has_Every_Category_And_The_Paths'Access,
         "The JSON has every category and the paths");
   end Register_Tests;

end Synapse.Core.Vault_Status.Tests;
