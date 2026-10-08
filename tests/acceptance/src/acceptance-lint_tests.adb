with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Acceptance.Fixtures;

package body Acceptance.Lint_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Is_Lower (C : Character) return Boolean is (C in 'a' .. 'z');

   function Is_Alpha (C : Character) return Boolean is
     (C in 'a' .. 'z' | 'A' .. 'Z');

   function Is_Alnum (C : Character) return Boolean is
     (Is_Alpha (C) or else C in '0' .. '9');

   function Without_Return (Line : String) return String is
     (if Line'Length > 0 and then Line (Line'Last) = Character'Val (13) then
        Line (Line'First .. Line'Last - 1)
      else Line);

   ---------------------------------------------------------------------------
   --  cli.md
   ---------------------------------------------------------------------------

   --  `$(...)` strips trailing newlines, so a closing fence printed directly
   --  after help text can land on the same line as that text and close
   --  nothing: every block from there on opens where it should have closed,
   --  and an unfenced `<file>`, `<node>` or `<s>` then reaches a Markdown
   --  renderer as an HTML tag.
   procedure The_Cli_Reference_Keeps_Every_Fence_On_Its_Own_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Fences   : Natural := 0;
      In_Fence : Boolean := False;
      Number   : Natural := 0;
   begin
      for Item of Lines (Read_File (Checkout & "/docs/synapse/cli.md")) loop
         Number := Number + 1;
         declare
            Line : constant String := Without_Return (To_String (Item));
         begin
            if Contains (Line, "```") then
               Assert_Equal (Line, "```", "a fence shares its line");
               Fences   := Fences + 1;
               In_Fence := not In_Fence;
            elsif not In_Fence then
               for I in Line'Range loop
                  if Line (I) = '<' and then I < Line'Last
                    and then
                    (Is_Alpha (Line (I + 1)) or else Line (I + 1) = '/')
                  then
                     Assert
                       (False,
                        "cli.md:" & Natural'Image (Number) &
                        ": unfenced angle bracket: " & Line);
                  end if;
               end loop;
            end if;
         end;
      end loop;
      Assert (Fences mod 2 = 0, "an unclosed fence");
   end The_Cli_Reference_Keeps_Every_Fence_On_Its_Own_Line;

   ---------------------------------------------------------------------------
   --  Shipped files
   ---------------------------------------------------------------------------

   --  macOS `mktemp` and `mktemp -d` ignore TMPDIR unless given a template, so
   --  a bare call writes to the system temp directory whatever the caller
   --  meant. Every shipped hook is `.cjs`, whose temp files respect TMPDIR;
   --  this checks again the moment a `.sh` hook reappears.
   procedure No_Shipped_Sh_Hook_Calls_Mktemp_Bare (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant String := Checkout & "/packages/synapse/lib";
   begin
      if not Exists (Dir) then
         return;
      end if;
      for Name of Files_In (Dir, ".sh") loop
         for Item of Lines (Read_File (Dir & "/" & To_String (Name))) loop
            declare
               Line  : constant String  := To_String (Item);
               At_Mk : constant Natural :=
                 Ada.Strings.Fixed.Index (Line, "mktemp");
            begin
               if At_Mk > 0 then
                  declare
                     After : Natural := At_Mk + 6;
                  begin
                     while After <= Line'Last and then Line (After) = ' ' loop
                        After := After + 1;
                     end loop;
                     if After + 1 <= Line'Last
                       and then Line (After .. After + 1) = "-d"
                     then
                        After := After + 2;
                        while After <= Line'Last and then Line (After) = ' '
                        loop
                           After := After + 1;
                        end loop;
                     end if;
                     Assert
                       (not
                        (After > Line'Last or else Line (After) in ')' | '|'),
                        To_String (Name) & ": bare mktemp (no template): " &
                        Line);
                  end;
               end if;
            end;
         end loop;
      end loop;
   end No_Shipped_Sh_Hook_Calls_Mktemp_Bare;

   --  A `synapse` or `second-brain` word followed by `.sh`.
   function Has_Legacy_Shell_Entry_Point (Line : String) return Boolean is
      Synapse_Word : aliased constant String := "synapse";
      Brain_Word   : aliased constant String := "second-brain";
      Prefixes     : constant array (1 .. 2) of access constant String :=
        [Synapse_Word'Access, Brain_Word'Access];
   begin
      for I in Line'Range loop
         for P of Prefixes loop
            if Line'Last - I + 1 >= P'Length
              and then Line (I .. I + P'Length - 1) = P.all
            then
               declare
                  J : Natural := I + P'Length;
               begin
                  while J <= Line'Last
                    and then (Is_Lower (Line (J)) or else Line (J) = '-')
                  loop
                     J := J + 1;
                  end loop;
                  if J + 2 <= Line'Last and then Line (J .. J + 2) = ".sh" then
                     return True;
                  end if;
               end;
            end if;
         end loop;
      end loop;
      return False;
   end Has_Legacy_Shell_Entry_Point;

   --  `~/.synapse` not continued by a letter, digit or underscore.
   function Has_Known_Dead_Identifier (Line : String) return Boolean is
      Needle : constant String := "~/.synapse";
      Start  : Natural         := Line'First;
   begin
      while Start <= Line'Last loop
         declare
            Pos : constant Natural :=
              Ada.Strings.Fixed.Index (Line (Start .. Line'Last), Needle);
         begin
            exit when Pos = 0;
            declare
               After : constant Natural := Pos + Needle'Length;
            begin
               if After > Line'Last
                 or else not
                 (Is_Alnum (Line (After)) or else Line (After) = '_')
               then
                  return True;
               end if;
            end;
            Start := Pos + 1;
         end;
      end loop;
      return False;
   end Has_Known_Dead_Identifier;

   --  Every `.md` file below Dir, as paths relative to Base.
   package Path_Vectors is new Ada.Containers.Vectors
     (Positive, Unbounded_String);

   procedure Collect
     (Dir, Suffix : String; Found : in out Path_Vectors.Vector)
   is
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      use type Ada.Directories.File_Kind;
   begin
      Ada.Directories.Start_Search
        (Search, Dir, "",
         [Ada.Directories.Ordinary_File | Ada.Directories.Directory => True,
         others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
            Full : constant String := Ada.Directories.Full_Name (Item);
         begin
            if Name in "." | ".." then
               null;
            elsif Ada.Directories.Kind (Item) = Ada.Directories.Directory then
               Collect (Full, Suffix, Found);
            elsif Name'Length >= Suffix'Length
              and then Name (Name'Last - Suffix'Length + 1 .. Name'Last)
                       = Suffix
            then
               Found.Append (To_Unbounded_String (Full));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
   end Collect;

   --  The rewrite deleted every `*.sh` entry point in favour of the compiled
   --  program. Matched with the trailing `.sh` so it never fires on the
   --  program's own subcommands, and so a comment in the source recording
   --  where something came from stays legal: nothing a model or a person is
   --  told to run may name one. `~/.synapse` is the config path before npm.
   procedure No_Instruction_Names_A_Deleted_Entry_Point
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Base  : constant String := Checkout & "/packages/synapse/";
      Files : Path_Vectors.Vector;
      Bad   : Unbounded_String;
   begin
      Collect (Base, ".md", Files);
      for Path of Files loop
         declare
            Number : Natural := 0;
         begin
            for Item of Lines (Read_File (To_String (Path))) loop
               Number := Number + 1;
               declare
                  Line : constant String := To_String (Item);
               begin
                  if Has_Legacy_Shell_Entry_Point (Line)
                    or else Has_Known_Dead_Identifier (Line)
                  then
                     Append
                       (Bad,
                        "  packages/synapse/" &
                        To_String (Path) (Base'Length + 1 .. Length (Path)) &
                        ":" & Natural'Image (Number) & ": " & Line & LF);
                  end if;
               end;
            end loop;
         end;
      end loop;
      Assert_Equal (To_String (Bad), "", "deleted entry points still named");
   end No_Instruction_Names_A_Deleted_Entry_Point;

   ---------------------------------------------------------------------------
   --  Codex mirrors
   ---------------------------------------------------------------------------

   type Template_Item is record
      Schema : Unbounded_String;
      Item   : Unbounded_String;
   end record;

   package Item_Vectors is new Ada.Containers.Vectors
     (Positive, Template_Item);

   package Text_Vectors is new Ada.Containers.Vectors
     (Positive, Unbounded_String);

   function Left_Trim (Text : String) return String is
      First : Natural := Text'First;
   begin
      while First <= Text'Last and then Text (First) in ' ' | ASCII.HT loop
         First := First + 1;
      end loop;
      return Text (First .. Text'Last);
   end Left_Trim;

   --  Every fenced block holding a `schema: vault-*` line, as one
   --  `field:<name>` or `heading:<text>` entry per frontmatter field or
   --  Markdown heading in it. Indentation is stripped first, since a
   --  template inside a numbered step is indented. Keyed by schema and not by
   --  position, so a file with more than one template compares each against
   --  its own counterpart.
   function Template_Fields_And_Headings
     (Text : String) return Item_Vectors.Vector
   is
      Result   : Item_Vectors.Vector;
      In_Fence : Boolean := False;
      In_Front : Boolean := False;
      Schema   : Unbounded_String;
      Items    : Text_Vectors.Vector;
   begin
      for Raw of Lines (Text) loop
         declare
            Line : constant String := Left_Trim (To_String (Raw));
         begin
            if Starts_With (Line, "```") then
               if In_Fence then
                  if Length (Schema) > 0 then
                     for It of Items loop
                        Result.Append (Template_Item'(Schema, It));
                     end loop;
                  end if;
                  Items.Clear;
                  In_Fence := False;
               else
                  In_Fence := True;
                  Schema   := Null_Unbounded_String;
                  In_Front := False;
               end if;
            elsif In_Fence then
               if Line = "---" then
                  In_Front := not In_Front;
               elsif In_Front and then Starts_With (Line, "schema: ") then
                  Schema :=
                    To_Unbounded_String (Line (Line'First + 8 .. Line'Last));
               else
                  declare
                     Handled : Boolean := False;
                  begin
                     if In_Front then
                        declare
                           Colon : constant Natural :=
                             Ada.Strings.Fixed.Index (Line, ":");
                        begin
                           if Colon > Line'First then
                              declare
                                 Key       : constant String :=
                                   Line (Line'First .. Colon - 1);
                                 Field_Key : Boolean         := True;
                              begin
                                 for C of Key loop
                                    if not (Is_Lower (C) or else C = '_') then
                                       Field_Key := False;
                                    end if;
                                 end loop;
                                 if Field_Key then
                                    Items.Append
                                      (To_Unbounded_String ("field:" & Key));
                                    Handled := True;
                                 end if;
                              end;
                           end if;
                        end;
                     end if;
                     if not Handled and then Line'Length > 0
                       and then Line (Line'First) = '#'
                     then
                        declare
                           I : Natural := Line'First;
                        begin
                           while I <= Line'Last and then Line (I) = '#' loop
                              I := I + 1;
                           end loop;
                           if I <= Line'Last and then Line (I) = ' ' then
                              Items.Append
                                (To_Unbounded_String ("heading:" & Line));
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;
      return Result;
   end Template_Fields_And_Headings;

   --  A Codex skill that silently drops a step its canonical command has is
   --  caught here and not by inspection. Scoped to what can safely be
   --  compared structurally, the note template each command produces, and not
   --  the prose around it, which differs between a slash command's positional
   --  arguments and Codex's own way of being invoked.
   procedure Every_Codex_Mirror_Keeps_The_Template_Of_Its_Command
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Commands : constant String := Checkout & "/packages/synapse/commands";
      Bad      : Unbounded_String;
   begin
      for File of Files_In (Commands, ".md") loop
         declare
            Name   : constant String :=
              To_String (File) (1 .. Length (File) - 3);
            Mirror : constant String :=
              "packages/synapse/harness/codex/skills/" & Name & "/SKILL.md";
         begin
            if Exists (Checkout & "/" & Mirror) then
               declare
                  Canon    : constant Item_Vectors.Vector :=
                    Template_Fields_And_Headings
                      (Read_File (Commands & "/" & To_String (File)));
                  Mirrored : constant Item_Vectors.Vector :=
                    Template_Fields_And_Headings
                      (Read_File (Checkout & "/" & Mirror));
               begin
                  for C of Canon loop
                     declare
                        Found : Boolean := False;
                     begin
                        for M of Mirrored loop
                           if M.Schema = C.Schema and then M.Item = C.Item then
                              Found := True;
                           end if;
                        end loop;
                        if not Found then
                           Append
                             (Bad,
                              "  " & Name & ": " & Mirror & " missing " &
                              To_String (C.Schema) & ASCII.HT &
                              To_String (C.Item) & LF);
                        end if;
                     end;
                  end loop;
               end;
            end if;
         end;
      end loop;
      Assert_Equal
        (To_String (Bad), "", "a Codex mirror dropped template parts");
   end Every_Codex_Mirror_Keeps_The_Template_Of_Its_Command;

   ---------------------------------------------------------------------------
   --  Layering
   ---------------------------------------------------------------------------

   --  The units a source file names in its context clauses.
   function Withed_Units (Text : String) return Text_Vectors.Vector is
      Result  : Text_Vectors.Vector;
      Clause  : Unbounded_String;
      Reading : Boolean := False;

      procedure Finish is
         Item : Unbounded_String;
         Text : constant String := To_String (Clause) & ",";
      begin
         for C of Text loop
            if C = ',' then
               if Length (Item) > 0 then
                  Result.Append (Item);
               end if;
               Item := Null_Unbounded_String;
            elsif C not in ' ' | ASCII.HT | LF then
               Append (Item, C);
            end if;
         end loop;
         Clause := Null_Unbounded_String;
         Reading := False;
      end Finish;
   begin
      for Raw of Lines (Text) loop
         declare
            Line : constant String := Left_Trim (To_String (Raw));
            Rest : constant String :=
              (if Starts_With (Line, "with ")
               then Line (Line'First + 5 .. Line'Last)
               elsif Starts_With (Line, "limited with ")
                 or else Starts_With (Line, "private with ")
               then Line (Line'First + 13 .. Line'Last)
               elsif Reading then Line
               else "");
         begin
            if Rest /= "" then
               Reading := True;
               declare
                  Semi : constant Natural :=
                    Ada.Strings.Fixed.Index (Rest, ";");
               begin
                  if Semi > 0 then
                     Append (Clause, Rest (Rest'First .. Semi - 1));
                     Finish;
                  else
                     Append (Clause, Rest & ",");
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Withed_Units;

   function Is_Unit_Or_Child (Name, Unit : String) return Boolean is
     (Name = Unit or else Starts_With (Name, Unit & "."));

   Core_Dir     : aliased constant String := "core";
   Ports_Dir    : aliased constant String := "ports";
   Adapters_Dir : aliased constant String := "adapters";

   --  `core`, `ports` and `adapters` never `with` `commands`, `hooks` or
   --  `apps`, so that a later split into a library and executables moves
   --  directories and project files only.
   procedure No_Lower_Layer_Names_A_Higher_One (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Lower : constant array (1 .. 3) of access constant String :=
        [Core_Dir'Access, Ports_Dir'Access, Adapters_Dir'Access];
      Bad   : Unbounded_String;
      Files : Path_Vectors.Vector;
   begin
      for Dir of Lower loop
         Collect (Checkout & "/src/" & Dir.all, ".ads", Files);
         Collect (Checkout & "/src/" & Dir.all, ".adb", Files);
      end loop;
      Assert (not Files.Is_Empty, "no sources found to check");
      for Path of Files loop
         for Unit of Withed_Units (Read_File (To_String (Path))) loop
            declare
               Name : constant String := To_String (Unit);
            begin
               if Is_Unit_Or_Child (Name, "Synapse.Commands")
                 or else Is_Unit_Or_Child (Name, "Synapse.Hooks")
                 or else Is_Unit_Or_Child (Name, "Synapse.Apps")
               then
                  Append
                    (Bad,
                     "  " &
                     To_String (Path) (Checkout'Length + 2 .. Length (Path)) &
                     " withs " & Name & LF);
               end if;
            end;
         end loop;
      end loop;
      Assert_Equal (To_String (Bad), "", "a lower layer names a higher one");
   end No_Lower_Layer_Names_A_Higher_One;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: consistency of the shipped text");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Cli_Reference_Keeps_Every_Fence_On_Its_Own_Line'Access,
         "docs/synapse/cli.md keeps every fence on its own line");
      Register_Routine
        (T, No_Shipped_Sh_Hook_Calls_Mktemp_Bare'Access,
         "no shipped .sh hook calls mktemp without a template");
      Register_Routine
        (T, No_Instruction_Names_A_Deleted_Entry_Point'Access,
         "no instruction names a deleted entry point or dead identifier");
      Register_Routine
        (T, No_Lower_Layer_Names_A_Higher_One'Access,
         "core, ports and adapters never name commands, hooks or apps");
      Register_Routine
        (T, Every_Codex_Mirror_Keeps_The_Template_Of_Its_Command'Access,
         "every command's note template is in its Codex mirror");
   end Register_Tests;

end Acceptance.Lint_Tests;
