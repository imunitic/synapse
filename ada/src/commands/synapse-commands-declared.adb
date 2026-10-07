with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.Disk_Repo_Reader;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Enumerate;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Deps;
with Synapse.Core.Namespace;
with Synapse.Ports.Variables;

package body Synapse.Commands.Declared is

   use Ada.Strings.Unbounded;
   use type Enumerate.Listing_Failure;

   package Support renames Synapse.Commands.Graph_Support;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   type Kind is (Dependencies, Namespaces);

   function Prog (Which : Kind) return String is
     (if Which = Dependencies then "synapse-build-deps"
      else "synapse-build-namespaces");

   function Usage_Text (Which : Kind) return String is
     ("usage: synapse " &
      (if Which = Dependencies then "build-deps" else "build-namespaces") &
      " [--repo <path>] [--out <path>]" & LF & LF &
      "  --repo   the checkout to scan. Default: the one containing $PWD." &
      LF & "  --out    where to write the index. Default $SYNAPSE_WORK_DIR/" &
      (if Which = Dependencies then "_deps.tsv." else "_namespaces.tsv.") &
      LF);

   function Variable (Env : Environment; Name : String) return String is
      Got : constant Ports.Variables.Maybe_Value := Env.Vars.Get (Name);
   begin
      return (if Got.Found then To_String (Got.Value) else "");
   end Variable;

   --  The rules of Which: the variable names a file, else the tiers, else
   --  the home's. A missing file is no rules. False after saying why not.
   procedure Load_Rules
     (Env :     Environment; Which : Kind; Rules : out Core.Namespace.Registry;
      Ok  : out Boolean)
   is
      Variable_Name : constant String                         :=
        (if Which = Dependencies then "SYNAPSE_DEPENDENCY_RULES_CONF"
         else "SYNAPSE_NAMESPACE_RULES_CONF");
      Conf_Name     : constant String                         :=
        (if Which = Dependencies then "synapse-dependency-rules.conf"
         else "synapse-namespace-rules.conf");
      Found         : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Resolve_Conf_Path (Env.Vars.all, Conf_Name);
      Path          : constant String                         :=
        (if Env.Vars.Get (Variable_Name).Found then
           Variable (Env, Variable_Name)
         elsif Found.Found then To_String (Found.Value)
         else Variable (Env, "HOME") & "/.claude/" & Conf_Name);
      Text          : Unbounded_String;
      Read          : Boolean;
   begin
      Rules := Core.Namespace.Parse ("{}");
      Ok    := True;
      Support.Read_File (Path, 8 * 1_024 * 1_024, Text, Read);
      if Read then
         Rules := Core.Namespace.Parse (To_String (Text));
      elsif Ada.Directories.Exists (Path) then
         Ok := False;
      end if;
   exception
      when Core.Namespace.Malformed =>
         Ok := False;
   end Load_Rules;

   function Run_Kind
     (Env : Environment; Args : Lists.Vector; Which : Kind) return Exit_Code
   is
      Repo, Out_Path      : Unbounded_String;
      Have_Repo, Have_Out : Boolean  := False;
      I                   : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg   : constant String := To_String (Args (I));
            Value : Unbounded_String;
            Found : Boolean;
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text (Which));
               return 0;
            elsif Arg in "--repo" | "--out" then
               Cli_Args.Take_Value (Args, I, Value, Found);
               if not Found then
                  return Usage_Error (Env, Usage_Text (Which));
               end if;
               if Arg = "--repo" then
                  Repo      := Value;
                  Have_Repo := True;
               else
                  Out_Path := Value;
                  Have_Out := True;
               end if;
            else
               return Usage_Error (Env, Usage_Text (Which));
            end if;
         end;
         I := I + 1;
      end loop;

      declare
         Root : constant String :=
           Support.Repo_Root
             (Env, (if Have_Repo then To_String (Repo) else ""));
      begin
         if Root = "" then
            Complain (Env, Prog (Which) & ": not inside a git repo" & LF);
            return 1;
         end if;
         if not Env.Vars.Get ("HOME").Found then
            return 1;
         end if;
         declare
            Rules   : Core.Namespace.Registry;
            Ok      : Boolean;
            Target  : Unbounded_String := Out_Path;
            Tracked : Lists.Vector;
            Failure : Enumerate.Listing_Failure;
         begin
            Load_Rules (Env, Which, Rules, Ok);
            if not Ok then
               Complain
                 (Env,
                  Prog (Which) & ": cannot read the " &
                  (if Which = Dependencies then "dependency"
                   else "namespace") &
                  "-rules registry" & LF);
               return 1;
            end if;
            if not Have_Out then
               declare
                  Work : constant Support.Maybe_Path :=
                    Support.Work_Dir (Env, Prog (Which), Root);
               begin
                  if not Work.Found then
                     return 1;
                  end if;
                  Target :=
                    Work.Value &
                    (if Which = Dependencies then "/_deps.tsv"
                     else "/_namespaces.tsv");
               end;
            end if;
            Enumerate.Tracked_Files (Env, Root, Tracked, Failure);
            if Failure = Enumerate.Git_Failed then
               Complain
                 (Env, Prog (Which) & ": git ls-files failed in " & Root & LF);
               return 1;
            elsif Failure = Enumerate.Grep_Failed then
               Complain (Env, Prog (Which) & ": grep failed" & LF);
               return 1;
            end if;

            declare
               Reader   : Adapters.Disk_Repo_Reader.Reader :=
                 Adapters.Disk_Repo_Reader.Create (Root);
               Out_Text : Unbounded_String;
               Count    : Natural;
            begin
               if Which = Dependencies then
                  declare
                     Found : constant Core.Deps.Row_Vectors.Vector :=
                       Core.Deps.Compute (Reader, Tracked, Rules);
                  begin
                     Count := Natural (Found.Length);
                     for Row of Found loop
                        Append (Out_Text, Core.Deps.Image (Row));
                     end loop;
                  end;
               else
                  declare
                     Found : constant Core.Namespace.Row_Vectors.Vector :=
                       Core.Namespace.Compute_Per_File
                         (Reader, Tracked, Rules);
                  begin
                     Count := Natural (Found.Length);
                     for Row of Found loop
                        Append (Out_Text, Row.Path & HT & Row.Namespace & LF);
                     end loop;
                  end;
               end if;
               Support.Write_File (To_String (Target), To_String (Out_Text));
               Complain
                 (Env,
                  Prog (Which) & ": " & Core.Decimal_Image.Image (Count) &
                  (if Which = Dependencies then " edge(s) -> "
                   else " row(s) -> ") &
                  To_String (Target) & LF);
               return 0;
            end;
         end;
      end;
   end Run_Kind;

   function Run_Deps
     (Env : Environment; Args : Lists.Vector) return Exit_Code is
     (Run_Kind (Env, Args, Dependencies));

   function Run_Namespaces
     (Env : Environment; Args : Lists.Vector) return Exit_Code is
     (Run_Kind (Env, Args, Namespaces));

end Synapse.Commands.Declared;
