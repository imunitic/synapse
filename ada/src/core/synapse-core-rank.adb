with Synapse.Core.Vocab;

package body Synapse.Core.Rank is

   function Ends_With (Text, Suffix : String) return Boolean is
     (Text'Length >= Suffix'Length
      and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix);

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Base_Name (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (I + 1 .. Path'Last);
         end if;
      end loop;
      return Path;
   end Base_Name;

   function Last_Dot (Name : String) return Natural is
   begin
      for I in reverse Name'Range loop
         if Name (I) = '.' then
            return I;
         end if;
      end loop;
      return 0;
   end Last_Dot;

   function Is_Test_Directory (Segment : String) return Boolean is
     (Segment in
        "test" | "tests" | "spec" | "specs" | "__tests__" | "testing");

   --  A directory segment is any but the last component, which is the file.
   function Has_Test_Segment (Path : String) return Boolean is
      Start : Positive := Path'First;
   begin
      for I in Path'Range loop
         if Path (I) = '/' then
            if Is_Test_Directory (Path (Start .. I - 1)) then
               return True;
            end if;
            Start := I + 1;
         end if;
      end loop;
      return False;
   end Has_Test_Segment;

   --  `FooTest`, `FooTests`, `FooSpec`: only after a lowercase letter, a digit
   --  or a dot.
   function Ends_With_Capitalised_Test (Stem : String) return Boolean is

      function After_Allowed (Suffix : String) return Boolean is
      begin
         if not Ends_With (Stem, Suffix) or else Stem'Length = Suffix'Length
         then
            return False;
         end if;
         declare
            Previous : constant Character := Stem (Stem'Last - Suffix'Length);
         begin
            return Previous in 'a' .. 'z' | '0' .. '9' | '.';
         end;
      end After_Allowed;

   begin
      return
        After_Allowed ("Tests") or else After_Allowed ("Test")
        or else After_Allowed ("Spec");
   end Ends_With_Capitalised_Test;

   --  `foo.test`, `foo_tests`, `foo-spec` as the stem.
   function Ends_With_Separated_Test (Stem : String) return Boolean is

      function After_Separator (Word : String) return Boolean is
      begin
         if not Ends_With (Stem, Word) or else Stem'Length = Word'Length then
            return False;
         end if;
         return Stem (Stem'Last - Word'Length) in '.' | '_' | '-';
      end After_Separator;

   begin
      return
        After_Separator ("test") or else After_Separator ("tests")
        or else After_Separator ("spec");
   end Ends_With_Separated_Test;

   function Is_Test (Path : String) return Boolean is
   begin
      if Has_Test_Segment (Path) then
         return True;
      end if;
      declare
         Name : constant String  := Base_Name (Path);
         Dot  : constant Natural := Last_Dot (Name);
      begin
         if Dot = 0 then
            return False;
         end if;
         declare
            Stem : constant String := Name (Name'First .. Dot - 1);
         begin
            return
              Ends_With_Capitalised_Test (Stem)
              or else Ends_With_Separated_Test (Stem)
              or else Starts_With (Name, "test_")
              or else Starts_With (Name, "Test_")
              or else (Stem'Length > 6 and then Ends_With (Stem, "_SUITE"));
         end;
      end;
   end Is_Test;

   function Key_Of (Path : String) return Key is
      Name   : constant String  := Base_Name (Path);
      Dot    : constant Natural := Last_Dot (Name);
      Module : constant String  := Vocab.Group_Of (Path, 2);
   begin
      return
        (Stem   =>
           To_Unbounded_String
             (if Dot = 0 then Name else Name (Name'First .. Dot - 1)),
         Module =>
           To_Unbounded_String
             (if Module = "" then Repo_Root_Module else Module),
         Path   => To_Unbounded_String (Path));
   end Key_Of;

   function Consumes (Declaration, Code : Key) return Boolean is
     (Length (Declaration.Stem) >= Min_Stem
      and then Declaration.Module = Code.Module
      and then Starts_With
        (To_String (Code.Stem), To_String (Declaration.Stem)));

   function Density
     (Definitions : Natural; Size_Bytes : Positive) return Long_Float is
     (Long_Float (Definitions) * 1_000.0 / Long_Float (Size_Bytes));

end Synapse.Core.Rank;
