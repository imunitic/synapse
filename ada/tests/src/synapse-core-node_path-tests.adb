with AUnit.Assertions;

package body Synapse.Core.Node_Path.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Safe (Node : String) is
   begin
      Assert (Is_Safe (Node), "safe: '" & Node & "'");
   end Safe;

   procedure Unsafe (Node : String) is
   begin
      Assert (not Is_Safe (Node), "unsafe: '" & Node & "'");
   end Unsafe;

   procedure Ordinary_Names_Are_Safe (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Safe ("Foo.md");
      Safe ("designs/synapse/sb-001.md");
      Safe ("");
      Safe ("a");
      Safe ("./Foo.md");  --  a single dot is not a traversal
      Safe (".config.md");
      Safe ("a/.hidden/b.md");
      Safe ("a..b.md");
      Safe ("a/..b");
      Safe ("a/b..");
      Safe ("...");
      Safe ("a/.../b");
      Safe ("a//b");
      Safe ("trailing/");
   end Ordinary_Names_Are_Safe;

   procedure Traversal_Is_Refused_Anywhere (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Unsafe ("..");
      Unsafe ("../x");
      Unsafe ("../../../../etc/passwd");
      Unsafe ("a/../../b.md");
      Unsafe ("a/..");
      Unsafe ("a/../b");
      Unsafe ("a/b/../../c");
   end Traversal_Is_Refused_Anywhere;

   procedure Absolute_Names_Are_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Unsafe ("/etc/passwd");
      Unsafe ("/");
      Unsafe ("//share/x");
   end Absolute_Names_Are_Refused;

   procedure Backslashes_Are_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Unsafe ("a\b");
      Unsafe ("..\x");
      Unsafe ("a\..\b");
      Unsafe ("\");
      Unsafe ("C:\x");
   end Backslashes_Are_Refused;

   --  Every segment of a name that is safe, however it is built from pieces,
   --  is not `..`.
   procedure Safe_Names_Built_From_Pieces_Never_Contain_Parent_Segments
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Pieces : constant array (0 .. 6) of String (1 .. 2) :=
        ["..", "a.", ".a", "/a", "a/", "..", "//"];
   begin
      for A in Pieces'Range loop
         for B in Pieces'Range loop
            for C in Pieces'Range loop
               declare
                  Name : constant String :=
                    Pieces (A) & Pieces (B) & Pieces (C);
                  Has_Segment : Boolean := False;
               begin
                  for I in 0 .. Name'Length - 1 loop
                     if Parent_Segment_At (Name, I) then
                        Has_Segment := True;
                     end if;
                  end loop;
                  Assert (Is_Safe (Name)
                          = (not Has_Segment
                             and then Name (Name'First) /= '/'),
                          "agrees on '" & Name & "'");
               end;
            end loop;
         end loop;
      end loop;
   end Safe_Names_Built_From_Pieces_Never_Contain_Parent_Segments;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Node_Path");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Ordinary_Names_Are_Safe'Access, "Ordinary names are safe");
      Register_Routine
        (T, Traversal_Is_Refused_Anywhere'Access,
         "Traversal is refused anywhere");
      Register_Routine
        (T, Absolute_Names_Are_Refused'Access, "Absolute names are refused");
      Register_Routine
        (T, Backslashes_Are_Refused'Access, "Backslashes are refused");
      Register_Routine
        (T, Safe_Names_Built_From_Pieces_Never_Contain_Parent_Segments'Access,
         "Names built from pieces agree with the segment rule");
   end Register_Tests;

end Synapse.Core.Node_Path.Tests;
