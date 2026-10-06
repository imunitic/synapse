with Ada.Containers;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Text_Lists;

package body Synapse.Adapters.Store_Contract is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   package Port renames Synapse.Ports.Store;

   LF : constant Character := Character'Val (10);

   procedure Check (S : in out Port.Store'Class) is
   begin
      Assert (not S.Read ("Missing.md").Found,
              "a missing node reads as nothing");
      Assert (S.List.Is_Empty, "a new store lists nothing");

      Assert (S.Write ("Foo.md", "---" & LF & "title: Foo" & LF & "---" & LF
                       & "body" & LF).Accepted, "a write is accepted");
      declare
         Got : constant Port.Maybe_Text := S.Read ("Foo.md");
      begin
         Assert (Got.Found, "the node reads back");
         Assert (To_String (Got.Text)
                 = "---" & LF & "title: Foo" & LF & "---" & LF & "body" & LF,
                 "byte for byte");
      end;

      Assert (S.Write ("Foo.md", "second").Accepted, "an overwrite");
      Assert (To_String (S.Read ("Foo.md").Text) = "second",
              "replaces the text");

      Assert (S.Write ("dir/Bar.md", "x").Accepted, "a nested node");
      Assert (S.Write ("Empty.md", "").Accepted, "an empty node");
      Assert (S.Read ("Empty.md").Found
              and then To_String (S.Read ("Empty.md").Text) = "",
              "empty is not missing");

      declare
         Names : constant Synapse.Core.Text_Lists.Vector := S.List;
      begin
         Assert (Names.Length = 3, "three nodes:" & Names.Length'Image);
         Assert (Names.Contains (To_Unbounded_String ("Foo.md"))
                 and then Names.Contains (To_Unbounded_String ("dir/Bar.md"))
                 and then Names.Contains (To_Unbounded_String ("Empty.md")),
                 "the names written");
      end;
   end Check;

end Synapse.Adapters.Store_Contract;
