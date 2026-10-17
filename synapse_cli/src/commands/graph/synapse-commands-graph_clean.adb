with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Commands.Cli_Args;
with Synapse.Commands.Context;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Graph_Clean;
with Synapse.Core.Node_Query;
with Synapse.Core.Optional_Text;
with Synapse.Ports.Process_Runner;

package body Synapse.Commands.Graph_Clean is

   use Ada.Strings.Unbounded;

   package Clean renames Synapse.Core.Graph_Clean;
   package Support renames Synapse.Commands.Graph_Support;
   package Runner renames Synapse.Ports.Process_Runner;

   use type Clean.Verdict_Kind;

   Prog : constant String    := "synapse-graph-clean";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse graph-clean [--dry-run]" & LF;

   Largest_Index : constant := 64 * 1_024 * 1_024;

   function Trimmed (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Text (First) in ' ' | HT | ASCII.CR | LF
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) in ' ' | HT | ASCII.CR | LF loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   --  What git printed on standard output, and whether it succeeded.
   procedure Git
     (Env    :     Environment; Root : String; Args : Lists.Vector;
      Output : out Unbounded_String; Ok : out Boolean)
   is
      Options : Runner.Options;
   begin
      Options.Cwd := To_Unbounded_String (Root);
      declare
         Done : constant Runner.Result :=
           Env.Runner.Run ("git", Args, Options);
      begin
         Output := Done.Output;
         Ok     := Runner.Succeeded (Done);
      end;
   exception
      when Runner.Process_Failure =>
         Output := Null_Unbounded_String;
         Ok     := False;
   end Git;

   function Git_Args (A1, A2, A3, A4, A5 : String := "") return Lists.Vector is
      Result : Lists.Vector;
   begin
      declare
         All_Args : constant array (1 .. 5) of access constant String :=
           [A1'Unrestricted_Access, A2'Unrestricted_Access,
           A3'Unrestricted_Access, A4'Unrestricted_Access,
           A5'Unrestricted_Access];
      begin
         for A of All_Args loop
            if A.all /= "" then
               Result.Append (To_Unbounded_String (A.all));
            end if;
         end loop;
      end;
      return Result;
   end Git_Args;

   function Ref_Exists
     (Env : Environment; Root, Prefix, Name : String) return Boolean
   is
      Ignored : Unbounded_String;
      Ok      : Boolean;
   begin
      Git
        (Env, Root,
         Git_Args ("show-ref", "--verify", "--quiet", Prefix & Name), Ignored,
         Ok);
      return Ok;
   end Ref_Exists;

   --  One setting of git, or none when unset or empty.
   function Config_Value
     (Env : Environment; Root, Key : String) return Core.Optional_Text.Option
   is
      Output : Unbounded_String;
      Ok     : Boolean;
   begin
      Git (Env, Root, Git_Args ("config", "--get", Key), Output, Ok);
      if not Ok or else Trimmed (To_String (Output)) = "" then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value => To_Unbounded_String (Trimmed (To_String (Output))));
   end Config_Value;

   function Gather
     (Env : Environment; Root : String; Branch : Core.Optional_Text.Option;
      Has_Remote : Boolean) return Clean.Facts
   is
      Facts : Clean.Facts;
   begin
      Facts.Branch     := Branch;
      Facts.Has_Remote := Has_Remote;
      if not Branch.Found or else Length (Branch.Value) = 0 then
         return Facts;
      end if;
      declare
         Name   : constant String := To_String (Branch.Value);
         Remote : constant Core.Optional_Text.Option :=
           Config_Value (Env, Root, "branch." & Name & ".remote");
         Merge  : constant Core.Optional_Text.Option :=
           Config_Value (Env, Root, "branch." & Name & ".merge");
      begin
         Facts.Local_Exists    := Ref_Exists (Env, Root, "refs/heads/", Name);
         Facts.Upstream_Remote := Remote;
         if Merge.Found then
            declare
               Text   : constant String := To_String (Merge.Value);
               Prefix : constant String := "refs/heads/";
            begin
               Facts.Upstream_Branch :=
                 (Found => True,
                  Value =>
                    To_Unbounded_String
                      (if
                         Text'Length >= Prefix'Length
                         and then
                           Text
                             (Text'First .. Text'First + Prefix'Length - 1) =
                           Prefix
                       then Text (Text'First + Prefix'Length .. Text'Last)
                       else Text));
            end;
         end if;
         if Remote.Found and then Facts.Upstream_Branch.Found then
            Facts.Upstream_Ref_Exists :=
              Ref_Exists
                (Env, Root, "refs/remotes/" & To_String (Remote.Value) & "/",
                 To_String (Facts.Upstream_Branch.Value));
         end if;
      end;
      return Facts;
   end Gather;

   --  Every `{Repo}@*` directory below `{Vault}/synapse`, in byte order.
   function Namespaces_For (Vault, Repo : String) return Lists.Vector is
      Root   : constant String := Vault & "/synapse";
      Prefix : constant String := Repo & "@";
      Found  : Lists.Vector;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;

      function Before (Left, Right : Unbounded_String) return Boolean is
        (Left < Right);

      package Sorting is new Lists.Vectors.Generic_Sorting (Before);
   begin
      if not Ada.Directories.Exists (Root) then
         return Found;
      end if;
      Ada.Directories.Start_Search
        (Search, Root, "*",
         [Ada.Directories.Directory => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name'Length >= Prefix'Length
              and then Name (Name'First .. Name'First + Prefix'Length - 1) =
                Prefix
            then
               Found.Append (To_Unbounded_String (Name));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      Sorting.Sort (Found);
      return Found;
   end Namespaces_For;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Dry_Run : Boolean := False;
   begin
      for Arg_Item of Args loop
         declare
            Arg : constant String := To_String (Arg_Item);
         begin
            if Arg = "--dry-run" then
               Dry_Run := True;
            elsif Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            else
               Complain (Env, Usage_Text);
               return 2;
            end if;
         end;
      end loop;

      declare
         Ctx : constant Context.Maybe_Context := Context.Resolve (Env, Prog);
      begin
         if not Ctx.Found then
            return 1;
         end if;
         declare
            Vault      : constant String  := To_String (Ctx.Value.Vault);
            Root       : constant String  := To_String (Ctx.Value.Repo_Root);
            Namespace  : constant String  := To_String (Ctx.Value.Namespace);
            At_Sign    : constant Natural :=
              Ada.Strings.Unbounded.Index (Ctx.Value.Namespace, "@");
            Repo       : constant String  :=
              (if At_Sign = 0 then Namespace
               else Namespace (Namespace'First .. At_Sign - 1));
            Remotes    : Unbounded_String;
            Listed     : Boolean;
            Has_Remote : Boolean;
            Removed    : Natural          := 0;
            Reported   : Natural          := 0;
         begin
            Git (Env, Root, Git_Args ("remote"), Remotes, Listed);
            Has_Remote := Listed and then Trimmed (To_String (Remotes)) /= "";

            if Has_Remote and then not Dry_Run then
               declare
                  Ignored : Unbounded_String;
                  Fetched : Boolean;
               begin
                  Git
                    (Env, Root, Git_Args ("fetch", "--prune", "--quiet"),
                     Ignored, Fetched);
                  if not Fetched then
                     Complain
                       (Env,
                        Prog & ": fetch failed -- deciding from local refs, " &
                        "which may be stale" & LF);
                  end if;
               end;
            end if;

            for Name of Namespaces_For (Vault, Repo) loop
               declare
                  Ns     : constant String := To_String (Name);
                  Ns_Dir : constant String := Vault & "/synapse/" & Ns;
                  Index  : Unbounded_String;
                  Read   : Boolean;
                  Branch : Core.Optional_Text.Option;
               begin
                  Support.Read_File
                    (Ns_Dir & "/Index.md", Largest_Index, Index, Read);
                  if Read then
                     Branch :=
                       Core.Node_Query.Field (To_String (Index), "branch");
                  end if;
                  declare
                     Branch_Name : constant String        :=
                       (if Branch.Found then To_String (Branch.Value) else "");
                     Verdict     : constant Clean.Verdict :=
                       Clean.Classify (Gather (Env, Root, Branch, Has_Remote));
                  begin
                     case Verdict.Kind is
                        when Clean.Keep =>
                           null;

                        when Clean.Report =>
                           Say
                             (Env,
                              "report" & HT & Ns & HT &
                              Clean.Reason_Text (Verdict.Why, Branch_Name) &
                              LF);
                           Reported := Reported + 1;

                        when Clean.Remove =>
                           declare
                              Gone : constant String :=
                                "upstream " &
                                To_String (Verdict.Upstream_Remote) & "/" &
                                To_String (Verdict.Upstream_Branch) &
                                " is gone";
                           begin
                              if Dry_Run then
                                 Say
                                   (Env,
                                    "would-remove" & HT & Ns & HT & Gone & LF);
                              elsif Support.Remove_Namespace
                                  (Env, Vault, Ns_Dir, Prog)
                              then
                                 Say
                                   (Env, "removed" & HT & Ns & HT & Gone & LF);
                              else
                                 goto Next_Namespace;
                              end if;
                              Removed := Removed + 1;
                           end;
                     end case;
                  end;
               end;
               <<Next_Namespace>>
               null;
            end loop;

            if Removed = 0 and then Reported = 0 then
               Say (Env, "nothing to clean" & LF);
            end if;
            return 0;
         end;
      end;
   end Run;

end Synapse.Commands.Graph_Clean;
