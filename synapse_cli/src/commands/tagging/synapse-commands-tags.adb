with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Commands.Graph_Support;
with Synapse.Commands.Tagging_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Grammar_Registry;
with Synapse.Core.Graph_Model;
with Synapse.Core.Kind_Synonyms;
with Synapse.Ports.Extractor;

package body Synapse.Commands.Tags is

   use Ada.Strings.Unbounded;

   package Registry_Types renames Synapse.Core.Grammar_Registry;
   package Support renames Synapse.Commands.Graph_Support;
   package Tagging renames Synapse.Commands.Tagging_Support;
   package Port renames Synapse.Ports.Extractor;

   use type Tagging.Load_Status;
   use type Port.Outcome_Kind;
   use type Registry_Types.Readiness_Kind;

   Prog : constant String    := "synapse-tags";
   LF   : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse tags <file>" & LF &
     "       synapse tags --paths <list-file>   every listed file, in one " &
     "batch" & LF &
     "       synapse tags --list-extensions     every extension with a " &
     "usable grammar" & LF;

   --  Longest expression a line echoes.
   Expression_Max : constant := 180;

   function Padded (Text : String; Width : Positive) return String is
     (Text & [1 .. Natural'Max (0, Width - Text'Length) => ' ']);

   function Image (N : Natural) return String is
     (Core.Decimal_Image.Image (N));

   --  One tag as `tree-sitter tags` prints it:
   --  `Token     <TAB> | class   <TAB>def (15, 13) - (15, 18) `public class T``.
   --  The name pads to ten columns and the kind to eight and neither is cut.
   --  The expression stops at 180 bytes, then loses its trailing blanks.
   function Line_Of (Item : Port.Located_Tag) return String is
      Raw  : constant String := To_String (Item.Item.Expression);
      Cut  : constant String :=
        (if Raw'Length > Expression_Max then
           Raw (Raw'First .. Raw'First + Expression_Max - 1)
         else Raw);
      Last : Natural         := Cut'Last;
   begin
      while Last >= Cut'First and then Cut (Last) in ' ' | ASCII.HT loop
         Last := Last - 1;
      end loop;
      return
        Padded (To_String (Item.Item.Name), 10) & ASCII.HT & " | " &
        Padded (To_String (Item.Item.Kind), 8) & ASCII.HT &
        Core.Graph_Model.Image (Item.Item.Which) & " (" &
        Image (Item.Where.Start_Row) & ", " & Image (Item.Where.Start_Col) &
        ") - (" & Image (Item.Where.End_Row) & ", " &
        Image (Item.Where.End_Col) & ") `" & Cut (Cut'First .. Last) & "`";
   end Line_Of;

   function List_Extensions
     (Env : Environment; Registry : Registry_Types.Registry) return Exit_Code
   is
      Out_Text : Unbounded_String;
   begin
      for Item of Registry_Types.Usable_Extensions (Registry) loop
         Append (Out_Text, Item);
         Append (Out_Text, LF);
      end loop;
      Say (Env, To_String (Out_Text));
      return 0;
   end List_Extensions;

   function Single
     (Env      : Environment; Extractor : in out Port.Locating_Extractor'Class;
      Registry : Registry_Types.Registry; Path : String) return Exit_Code
   is
   begin
      if not Ada.Directories.Exists (Path) then
         Complain (Env, Prog & ": no such file: " & Path & LF);
         return 1;
      end if;
      --  Asked before extracting, only to choose between 1 and 2: the
      --  extractor's `unsupported` is both "no entry" and "unusable".
      declare
         Extension : constant String := Registry_Types.Extension_Of (Path);
      begin
         if Extension = "" then
            return 1;
         end if;
         case Registry_Types.Lookup (Registry, Extension).Kind is
            when Registry_Types.Ready =>
               null;

            when Registry_Types.Unusable =>
               return 1;

            when Registry_Types.No_Entry =>
               return 2;
         end case;
      end;
      declare
         Paths   : Lists.Vector;
         Results : Port.Located_Outcome_Vectors.Vector;
      begin
         Paths.Append (To_Unbounded_String (Path));
         Results := Extractor.Extract_Located (".", Paths);
         declare
            Found    : constant Port.Located_Outcome := Results (1);
            Out_Text : Unbounded_String;
         begin
            if Found.Kind = Port.Unsupported then
               return 1;
            end if;
            for Item of Found.Tags loop
               Append (Out_Text, Line_Of (Item) & LF);
            end loop;
            Say (Env, To_String (Out_Text));
         end;
         return 0;
      end;
   end Single;

   function Batch
     (Env : Environment; Extractor : in out Port.Locating_Extractor'Class;
      List_File : String) return Exit_Code
   is
      Listing : Unbounded_String;
      Read    : Boolean;
      Paths   : Lists.Vector;
   begin
      Support.Read_File (List_File, 64 * 1_024 * 1_024, Listing, Read);
      if not Read then
         Complain (Env, Prog & ": unreadable paths file: " & List_File & LF);
         return 1;
      end if;
      declare
         Whole : constant String := To_String (Listing);
         Start : Positive        := Whole'First;
      begin
         for I in Whole'First .. Whole'Last + 1 loop
            if I > Whole'Last or else Whole (I) = LF then
               declare
                  First : Positive := Start;
                  Last  : Natural  := I - 1;
               begin
                  while First <= Last
                    and then Whole (First) in ' ' | ASCII.HT | ASCII.CR
                  loop
                     First := First + 1;
                  end loop;
                  while Last >= First
                    and then Whole (Last) in ' ' | ASCII.HT | ASCII.CR
                  loop
                     Last := Last - 1;
                  end loop;
                  if Last >= First then
                     Paths.Append
                       (To_Unbounded_String (Whole (First .. Last)));
                  end if;
                  Start := I + 1;
               end;
            end if;
         end loop;
      end;
      if Paths.Is_Empty then
         return 1;
      end if;

      declare
         Results  : constant Port.Located_Outcome_Vectors.Vector :=
           Extractor.Extract_Located (".", Paths);
         Usable   : Natural                                      := 0;
         Out_Text : Unbounded_String;
      begin
         for Item of Results loop
            if Item.Kind = Port.With_Tags then
               Usable := Usable + 1;
            end if;
         end loop;
         --  Better than an empty success that reads as "no symbols".
         if Usable = 0 then
            return 1;
         end if;
         --  A file that could not be parsed is absent; one that parsed to
         --  nothing still has its path line.
         for I in 1 .. Natural (Paths.Length) loop
            declare
               Found : constant Port.Located_Outcome := Results (I);
            begin
               if Found.Kind = Port.With_Tags then
                  Append (Out_Text, Paths (I));
                  Append (Out_Text, LF);
                  for Item of Found.Tags loop
                     Append (Out_Text, ASCII.HT & Line_Of (Item) & LF);
                  end loop;
               end if;
            end;
         end loop;
         Say (Env, To_String (Out_Text));
         return 0;
      end;
   end Batch;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if Args.Is_Empty then
         return Usage_Error (Env, Usage_Text);
      end if;
      declare
         First : constant String := To_String (Args (1));
      begin
         --  Before the registry: help needs neither a home nor a grammar.
         if First in "-h" | "--help" then
            Complain (Env, Usage_Text);
            return 0;
         end if;

         declare
            Registry      : Registry_Types.Registry;
            Registry_Path : Unbounded_String;
            Status        : Tagging.Load_Status;
         begin
            Tagging.Load_Registry (Env, Registry, Registry_Path, Status);
            if Status = Tagging.No_Home then
               Complain (Env, Prog & ": $HOME is not set" & LF);
               return 1;
            elsif Status = Tagging.Unreadable then
               Complain
                 (Env,
                  Prog & ": unreadable grammar registry: " &
                  To_String (Registry_Path) & LF);
               return 1;
            end if;
            if First = "--list-extensions" then
               return List_Extensions (Env, Registry);
            end if;

            declare
               Dir        : Unbounded_String;
               Have_Dir   : Boolean;
               Rules      : Core.Kind_Synonyms.Rule_List;
               Rules_Path : Unbounded_String;
            begin
               Tagging.Grammars_Dir (Env, Dir, Have_Dir);
               Tagging.Load_Rules (Env, Rules, Rules_Path, Status);
               if Status /= Tagging.Loaded then
                  Complain
                    (Env,
                     Prog & ": unreadable kind-synonyms conf: " &
                     To_String (Rules_Path) & LF);
                  return 1;
               end if;
               declare
                  Extractor :
                    constant not null access Port.Locating_Extractor'Class :=
                    Env.Extractors.Locating
                      (Tagging.Settings_For
                         (Env, Registry, To_String (Dir), Rules));
               begin
                  if First = "--paths" then
                     if Natural (Args.Length) < 2 then
                        return 1;
                     end if;
                     return Batch (Env, Extractor.all, To_String (Args (2)));
                  end if;
                  return Single (Env, Extractor.all, Registry, First);
               end;
            end;
         end;
      end;
   end Run;

end Synapse.Commands.Tags;
