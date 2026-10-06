with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Synapse.Core.JSON;

package body Synapse.Core.Namespace is

   package J renames Synapse.Core.JSON;

   use type J.Kind;

   Blanks : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (" " & Character'Val (9));

   Blanks_And_CR : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (" " & Character'Val (9) & Character'Val (13));

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   --  The string member of an object, if it is one and is not empty.
   function Text_Member (Object : J.Value; Key : String) return Maybe_Text is
   begin
      if not J.Has_Member (Object, Key) then
         return (Found => False);
      end if;
      declare
         Item : constant J.Value := J.Member_Value (Object, Key);
      begin
         if J.Kind_Of (Item) = J.JSON_String and then J.As_String (Item) /= ""
         then
            return
              (Found => True,
               Text  => To_Unbounded_String (J.As_String (Item)));
         end if;
         return (Found => False);
      end;
   end Text_Member;

   function Parse_Rule (Object : J.Value; Result : out Rule) return Boolean is
      Kind_Text : constant Maybe_Text := Text_Member (Object, "kind");
      Prefix    : constant Maybe_Text := Text_Member (Object, "prefix");
   begin
      if not Kind_Text.Found or else not Prefix.Found then
         return False;
      end if;
      declare
         Name : constant String := To_String (Kind_Text.Text);
      begin
         if Name = "in-file" then
            Result.Which := In_File;
         elsif Name = "build-file" then
            Result.Which := Build_File;
         else
            return False;
         end if;
      end;
      Result.Prefix := Prefix.Text;
      Result.File   := Text_Member (Object, "file");
      if Result.Which = Build_File and then not Result.File.Found then
         return False;
      end if;
      Result.Terminator := Text_Member (Object, "terminator");
      Result.Aliases.Clear;
      if J.Has_Member (Object, "aliases") then
         declare
            List : constant J.Value := J.Member_Value (Object, "aliases");
         begin
            if J.Kind_Of (List) = J.JSON_Array then
               for I in 1 .. J.Length (List) loop
                  declare
                     Item            : constant J.Value := J.Element (List, I);
                     Prefix_Of_Alias : Maybe_Text;
                  begin
                     if J.Kind_Of (Item) = J.JSON_Object then
                        Prefix_Of_Alias := Text_Member (Item, "prefix");
                        if Prefix_Of_Alias.Found then
                           Result.Aliases.Append
                             (Alias'
                                (Prefix     => Prefix_Of_Alias.Text,
                                 Terminator =>
                                   Text_Member (Item, "terminator")));
                        end if;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end if;
      return True;
   end Parse_Rule;

   function Parse (Text : String) return Registry is
      Parsed : constant J.Parse_Result := J.Parse (Text);
      Result : Registry;
   begin
      if not Parsed.Ok then
         raise Malformed;
      end if;
      if J.Kind_Of (Parsed.Item) /= J.JSON_Object then
         return Result;
      end if;
      for I in 1 .. J.Length (Parsed.Item) loop
         declare
            Item  : constant J.Value := J.Member_At (Parsed.Item, I);
            Found : Rule;
         begin
            if J.Kind_Of (Item) = J.JSON_Object
              and then Parse_Rule (Item, Found)
            then
               Result.Rules.Include (J.Member_Key (Parsed.Item, I), Found);
            end if;
         end;
      end loop;
      return Result;
   end Parse;

   function Dir_Of (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (Path'First .. I - 1);
         end if;
      end loop;
      return "";
   end Dir_Of;

   function Base_Of (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (I + 1 .. Path'Last);
         end if;
      end loop;
      return Path;
   end Base_Of;

   function Rule_For_Path (R : Registry; Path : String) return Maybe_Rule is
      Base : constant String := Base_Of (Path);
   begin
      for I in reverse Base'Range loop
         if Base (I) = '.' then
            --  A leading dot is a hidden file, not an extension.
            if I = Base'First then
               return (Found => False);
            end if;
            declare
               Place : constant Rule_Maps.Cursor :=
                 R.Rules.Find (Base (I + 1 .. Base'Last));
            begin
               if Rule_Maps.Has_Element (Place) then
                  return (Found => True, Value => Rule_Maps.Element (Place));
               end if;
               return (Found => False);
            end;
         end if;
      end loop;
      return (Found => False);
   end Rule_For_Path;

   function Extract_Field
     (Content : String; Prefix : String; Terminator : Maybe_Text)
      return Maybe_Text
   is
      Start    : Integer            := Content'First;
      In_Block : Boolean            := False;
      LF       : constant Character := Character'Val (10);
   begin
      loop
         declare
            Stop : Integer := Start;
         begin
            while Stop <= Content'Last and then Content (Stop) /= LF loop
               Stop := Stop + 1;
            end loop;
            declare
               Line : constant String  :=
                 Ada.Strings.Fixed.Trim
                   (Content (Start .. Stop - 1), Blanks,
                    Ada.Strings.Maps.Null_Set);
               Open : constant Natural := Ada.Strings.Fixed.Index (Line, "/*");
            begin
               if In_Block then
                  if Ada.Strings.Fixed.Index (Line, "*/") > 0 then
                     In_Block := False;
                  end if;
               elsif Open > 0 then
                  --  The whole line is skipped even when it also closes the
                  --  comment: sharing a line with `/*` is not a declaration
                  --  alone on its line.
                  In_Block :=
                    Ada.Strings.Fixed.Index (Line (Open .. Line'Last), "*/") =
                    0;
               elsif Starts_With (Line, Prefix) then
                  declare
                     Rest : constant String :=
                       Line (Line'First + Prefix'Length .. Line'Last);
                     Cut  : Natural         := 0;
                     Skip : Boolean         := False;
                  begin
                     if Terminator.Found then
                        Cut  :=
                          Ada.Strings.Fixed.Index
                            (Rest, To_String (Terminator.Text));
                        Skip := Cut = 0;
                     end if;
                     if not Skip then
                        declare
                           Value : constant String :=
                             Ada.Strings.Fixed.Trim
                               ((if Terminator.Found then
                                   Rest (Rest'First .. Cut - 1)
                                 else Rest),
                                Blanks_And_CR, Blanks_And_CR);
                        begin
                           if Value /= "" then
                              return
                                (Found => True,
                                 Text  => To_Unbounded_String (Value));
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
            exit when Stop > Content'Last;
            Start := Stop + 1;
         end;
      end loop;
      return (Found => False);
   end Extract_Field;

   function Nearest_Namespace
     (By_Dir : Dir_Maps.Map; Dir : String) return Maybe_Text
   is
      Here : Unbounded_String := To_Unbounded_String (Dir);
   begin
      loop
         declare
            Place : constant Dir_Maps.Cursor := By_Dir.Find (To_String (Here));
         begin
            if Dir_Maps.Has_Element (Place) then
               return
                 (Found => True,
                  Text  => To_Unbounded_String (Dir_Maps.Element (Place)));
            end if;
            if Length (Here) = 0 then
               return (Found => False);
            end if;
            Here := To_Unbounded_String (Dir_Of (To_String (Here)));
         end;
      end loop;
   end Nearest_Namespace;

   --  The three parts of a rule joined by NUL, which no file name or
   --  configured prefix contains.
   function Cache_Key
     (File_Name, Prefix : String; Terminator : Maybe_Text) return String is
     (File_Name & Character'Val (0) & Prefix & Character'Val (0) &
      (if Terminator.Found then To_String (Terminator.Text) else ""));

   function Extract
     (Reader : in out Ports.Repo_Reader.Reader'Class; Kept : Text_Lists.Vector;
      Path       :    String; Which : Kind; File : Maybe_Text; Prefix : String;
      Terminator :    Maybe_Text; Cache : in out Build_Cache) return Maybe_Text
   is
   begin
      case Which is
         when In_File =>
            declare
               Content : constant Ports.Repo_Reader.Maybe_Content :=
                 Reader.Read (Path);
            begin
               if not Content.Found then
                  return (Found => False);
               end if;
               return
                 Extract_Field (To_String (Content.Text), Prefix, Terminator);
            end;

         when Build_File =>
            declare
               File_Name : constant String := To_String (File.Text);
               Key       : constant String :=
                 Cache_Key (File_Name, Prefix, Terminator);
            begin
               if not Cache.Maps.Contains (Key) then
                  declare
                     Declared : Dir_Maps.Map;
                  begin
                     for P of Kept loop
                        if Base_Of (To_String (P)) = File_Name then
                           declare
                              Content :
                                constant Ports.Repo_Reader.Maybe_Content :=
                                Reader.Read (To_String (P));
                           begin
                              if Content.Found then
                                 declare
                                    Raw : constant Maybe_Text :=
                                      Extract_Field
                                        (To_String (Content.Text), Prefix,
                                         Terminator);
                                 begin
                                    if Raw.Found then
                                       Declared.Include
                                         (Dir_Of (To_String (P)),
                                          To_String (Raw.Text));
                                    end if;
                                 end;
                              end if;
                           end;
                        end if;
                     end loop;
                     Cache.Maps.Insert (Key, Declared);
                  end;
               end if;
               return
                 Nearest_Namespace
                   (Cache.Maps.Constant_Reference (Key).Element.all,
                    Dir_Of (Path));
            end;
      end case;
   end Extract;

   function "<" (Left, Right : Row) return Boolean is
     (if Left.Path /= Right.Path then Left.Path < Right.Path
      else Left.Namespace < Right.Namespace);

   function Compute_Per_File
     (Reader : in out Ports.Repo_Reader.Reader'Class; Kept : Text_Lists.Vector;
      Rules  :        Registry) return Row_Vectors.Vector
   is
      package Sorting is new Row_Vectors.Generic_Sorting;

      Result : Row_Vectors.Vector;
      Cache  : Build_Cache;
   begin
      if Is_Empty (Rules) then
         return Result;
      end if;
      for P of Kept loop
         declare
            Path  : constant String     := To_String (P);
            Found : constant Maybe_Rule := Rule_For_Path (Rules, Path);
         begin
            if Found.Found then
               declare
                  Primary : constant Maybe_Text :=
                    Extract
                      (Reader, Kept, Path, Found.Value.Which, Found.Value.File,
                       To_String (Found.Value.Prefix), Found.Value.Terminator,
                       Cache);
               begin
                  if Primary.Found then
                     Result.Append
                       (Row'(Path => P, Namespace => Primary.Text));
                  end if;
               end;
               for A of Found.Value.Aliases loop
                  declare
                     Other : constant Maybe_Text :=
                       Extract
                         (Reader, Kept, Path, Found.Value.Which,
                          Found.Value.File, To_String (A.Prefix), A.Terminator,
                          Cache);
                  begin
                     if Other.Found then
                        Result.Append
                          (Row'(Path => P, Namespace => Other.Text));
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
      Sorting.Sort (Result);
      return Result;
   end Compute_Per_File;

end Synapse.Core.Namespace;
