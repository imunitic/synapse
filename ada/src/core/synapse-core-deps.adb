package body Synapse.Core.Deps is

   HT : constant Character := Character'Val (9);

   function Parse_Row (Line : String) return Maybe_Row is
      First_Tab : Natural := 0;
      Next_Tab  : Natural := 0;
   begin
      for I in Line'Range loop
         if Line (I) = HT then
            if First_Tab = 0 then
               First_Tab := I;
            else
               Next_Tab := I;
               exit;
            end if;
         end if;
      end loop;
      if First_Tab = 0 then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value =>
           (Path => To_Unbounded_String (Line (Line'First .. First_Tab - 1)),
            Library =>
              To_Unbounded_String
                (Line
                   (First_Tab + 1 ..
                        (if Next_Tab = 0 then Line'Last else Next_Tab - 1)))));
   end Parse_Row;

   function Split_Libraries (Raw : String) return Text_Lists.Vector is
      Result : Text_Lists.Vector;
      Start  : Natural := 0;

      function Is_Separator (C : Character) return Boolean is
        (C in ' ' | HT | Character'Val (13) | Character'Val (10) | ',');
   begin
      for I in Raw'Range loop
         if Is_Separator (Raw (I)) then
            if Start /= 0 then
               Result.Append (To_Unbounded_String (Raw (Start .. I - 1)));
               Start := 0;
            end if;
         elsif Start = 0 then
            Start := I;
         end if;
      end loop;
      if Start /= 0 then
         Result.Append (To_Unbounded_String (Raw (Start .. Raw'Last)));
      end if;
      return Result;
   end Split_Libraries;

   function "<" (Left, Right : Row) return Boolean is
     (if Left.Path /= Right.Path then Left.Path < Right.Path
      else Left.Library < Right.Library);

   function Compute
     (Reader : in out Ports.Repo_Reader.Reader'Class; Kept : Text_Lists.Vector;
      Rules  :        Namespace.Registry) return Row_Vectors.Vector
   is
      package Sorting is new Row_Vectors.Generic_Sorting;

      Result : Row_Vectors.Vector;
      Cache  : Namespace.Build_Cache;
   begin
      if Namespace.Is_Empty (Rules) then
         return Result;
      end if;
      for P of Kept loop
         declare
            Path  : constant String               := To_String (P);
            Found : constant Namespace.Maybe_Rule :=
              Namespace.Rule_For_Path (Rules, Path);
         begin
            if Found.Found then
               declare
                  Raw : constant Namespace.Maybe_Text :=
                    Namespace.Extract
                      (Reader, Kept, Path, Found.Value.Which, Found.Value.File,
                       To_String (Found.Value.Prefix), Found.Value.Terminator,
                       Cache);
               begin
                  if Raw.Found then
                     for Library of Split_Libraries (To_String (Raw.Text)) loop
                        Result.Append (Row'(Path => P, Library => Library));
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;
      Sorting.Sort (Result);
      return Result;
   end Compute;

   function Image (R : Row) return String is
     (To_String (R.Path) & HT & To_String (R.Library) & Character'Val (10));

end Synapse.Core.Deps;
