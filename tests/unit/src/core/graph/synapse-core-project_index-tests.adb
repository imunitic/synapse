with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

package body Synapse.Core.Project_Index.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF   : constant Character := Character'Val (10);
   Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   function Has (Text, Part : String) return Boolean
   is (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Ends (Text, Suffix : String) return Boolean
   is (Text'Length >= Suffix'Length
       and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix);

   function Sample return Params is
      Result : Params;
   begin
      Result.Namespace := To_Unbounded_String ("widget-core@master");
      Result.Project := To_Unbounded_String ("widget-core");
      Result.Branch := To_Unbounded_String ("master");
      Result.Remote :=
        To_Unbounded_String ("ssh://git@example.invalid/team/widget-core.git");
      Result.Built_At := To_Unbounded_String ("2026-08-12 20:16");
      Result.Total_Files := 124_817;
      Result.Bullets.Append
        (Bullet'(Link    => To_Unbounded_String ("Alerts and exceptions"),
                 Files   => 42,
                 Summary => To_Unbounded_String ("How failures surface.")));
      Result.Bullets.Append
        (Bullet'(Link    => To_Unbounded_String ("State machine"),
                 Files   => 19,
                 Summary => To_Unbounded_String ("How states advance.")));
      return Result;
   end Sample;

   procedure The_Index_Carries_Every_Field_Its_Readers_Check
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String := Image (Sample);
   begin
      Assert (Has (Text, LF & "project: widget-core" & LF), "project");
      Assert (Has (Text, LF & "branch: master" & LF), "branch");
      Assert (Has (Text, LF & "remote: ""ssh://git@example.invalid/team/"
                   & "widget-core.git""" & LF), "remote");
      Assert (Has (Text, "node_type: synapse-index" & LF), "node type");
      Assert (Has (Text, LF & "built_at: ""2026-08-12 20:16""" & LF),
              "built at");
      Assert (Has (Text, "124817 tracked files, 2 nodes."),
              "the node count is the bullet count");
      Assert (Ends (Text,
                    "- [[Alerts and exceptions]] " & Dash
                    & " How failures surface. (42 files)" & LF
                    & "- [[State machine]] " & Dash
                    & " How states advance. (19 files)" & LF),
              "the bullets, in the order given");
   end The_Index_Carries_Every_Field_Its_Readers_Check;

   procedure A_Namespace_With_No_Nodes_Is_Still_Readable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Empty : Params;
   begin
      Empty.Namespace := To_Unbounded_String ("r@main");
      Empty.Project := To_Unbounded_String ("r");
      Empty.Branch := To_Unbounded_String ("main");
      Empty.Built_At := To_Unbounded_String ("2026-08-12 20:16");
      declare
         Text : constant String := Image (Empty);
      begin
         Assert (Has (Text, "remote: """"" & LF), "an empty remote");
         Assert (Has (Text, "0 tracked files, 0 nodes."), "counts");
         Assert (not Has (Text, "- [["), "no bullets");
      end;
   end A_Namespace_With_No_Nodes_Is_Still_Readable;

   procedure The_Title_And_Heading_Are_The_Namespace_Key
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : Params := Sample;
   begin
      P.Namespace := To_Unbounded_String ("repo@feature/x");
      P.Project := To_Unbounded_String ("repo");
      P.Branch := To_Unbounded_String ("feature/x");
      declare
         Text : constant String := Image (P);
      begin
         Assert (Starts (Text, "---" & LF & "title: ""repo@feature/x " & Dash
                         & " Synapse index""" & LF), "the title");
         Assert (Has (Text, LF & "# repo@feature/x " & Dash & " Synapse index"
                      & LF), "the heading");
         Assert (Has (Text, "branch: feature/x" & LF),
                 "the branch as it is, apart from the key");
      end;
   end The_Title_And_Heading_Are_The_Namespace_Key;

   procedure The_Frontmatter_Is_Closed_Before_The_Heading
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String := Image (Sample);
      Fence : constant Natural := Ada.Strings.Fixed.Index (Text, LF & "---" & LF);
   begin
      Assert (Fence > 0, "a closing fence");
      Assert (Ada.Strings.Fixed.Index (Text, "# widget-core@master") > Fence,
              "the heading comes after it");
      Assert (Has (Text, "synapse index lookup <path>"),
              "the first paragraph says how to find a node by path");
      Assert (Has (Text, "synapse query body <node>"),
              "the second says how to read one");
   end The_Frontmatter_Is_Closed_Before_The_Heading;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Project_Index");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Index_Carries_Every_Field_Its_Readers_Check'Access,
         "The index carries every field its readers check");
      Register_Routine
        (T, A_Namespace_With_No_Nodes_Is_Still_Readable'Access,
         "A namespace with no nodes is still readable");
      Register_Routine
        (T, The_Title_And_Heading_Are_The_Namespace_Key'Access,
         "The title and heading are the namespace key");
      Register_Routine
        (T, The_Frontmatter_Is_Closed_Before_The_Heading'Access,
         "The frontmatter is closed before the heading");
   end Register_Tests;

end Synapse.Core.Project_Index.Tests;
