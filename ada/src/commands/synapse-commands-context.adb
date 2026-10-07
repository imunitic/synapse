with Ada.IO_Exceptions;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Git_Identity;
with Synapse.Core.Identity;
with Synapse.Core.Node_Query;

package body Synapse.Commands.Context is

   package Files renames Synapse.Adapters.File_Bytes;
   package Ports_Vars renames Synapse.Ports.Variables;

   Boilerplate_Conf : constant String := "synapse-module-boilerplate.conf";

   --  A variable's value when it is set and not empty.
   function Non_Empty
     (Env : Environment; Name : String) return Ports_Vars.Maybe_Value
   is
      Got : constant Ports_Vars.Maybe_Value := Env.Vars.Get (Name);
   begin
      if Got.Found and then Length (Got.Text) > 0 then
         return Got;
      end if;
      return (Found => False);
   end Non_Empty;

   function Value_Or
     (Got : Ports_Vars.Maybe_Value; Otherwise : String) return String is
     (if Got.Found then To_String (Got.Text) else Otherwise);

   function Home (Env : Environment) return String is
     (Value_Or (Env.Vars.Get ("HOME"), ""));

   function Work_Dir_For
     (Env : Environment; Namespace : String) return String is
     (Value_Or
        (Non_Empty (Env, "SYNAPSE_WORK_DIR"),
         Home (Env) & "/.cache/synapse/work/" & Namespace));

   procedure Load_Chains (Env : Environment; Into : in out Context) is
      Configured : constant Ports_Vars.Maybe_Value         :=
        Env.Vars.Get ("SYNAPSE_MODULE_BOILERPLATE_CONF");
      Found      : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Resolve_Conf_Path (Env.Vars.all, Boilerplate_Conf);
      Path       : constant String                         :=
        (if Configured.Found then To_String (Configured.Text)
         elsif Found.Found then To_String (Found.Path)
         elsif Home (Env) /= "" then
           Home (Env) & "/.claude/" & Boilerplate_Conf
         else "");
   begin
      if Path = "" then
         return;
      end if;
      declare
         Text  : constant String := Files.Read (Path, 1_048_576);
         Start : Positive        := Text'First;
      begin
         while Start <= Text'Last + 1 loop
            declare
               Stop  : Natural := Start;
               First : Positive;
               Last  : Natural;
            begin
               while Stop <= Text'Last and then Text (Stop) /= ASCII.LF loop
                  Stop := Stop + 1;
               end loop;
               Last := Stop - 1;
               for I in Start .. Stop - 1 loop
                  if Text (I) = '#' then
                     Last := I - 1;
                     exit;
                  end if;
               end loop;
               First := Start;
               while First <= Last
                 and then Text (First) in ' ' | ASCII.HT | ASCII.CR
               loop
                  First := First + 1;
               end loop;
               while Last >= First
                 and then Text (Last) in ' ' | ASCII.HT | ASCII.CR
               loop
                  Last := Last - 1;
               end loop;
               if Last >= First then
                  Into.Chains.Append
                    (To_Unbounded_String (Text (First .. Last)));
               end if;
               Start := Stop + 1;
            end;
         end loop;
      end;
   exception
      when Ada.IO_Exceptions.Name_Error =>
         null;
      when others                       =>
         Complain
           (Env,
            "synapse: unreadable module-boilerplate conf: " & Path & ASCII.LF);
   end Load_Chains;

   function Resolve (Env : Environment; Prog : String) return Maybe_Context is
      Vault    : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Vault_Dir (Env.Vars.all);
      Result   : Context;
      Resolved : Core.Identity.Resolved;
      Have_All : constant Boolean                        :=
        Non_Empty (Env, "SYNAPSE_NAMESPACE").Found
        and then Non_Empty (Env, "SYNAPSE_REPO_ROOT").Found
        and then Non_Empty (Env, "SYNAPSE_BRANCH").Found;
   begin
      if not Vault.Found then
         Complain (Env, Prog & ": no vault" & ASCII.LF);
         return (Found => False);
      end if;
      if not Have_All then
         begin
            Resolved := Adapters.Git_Identity.Resolve (".");
         exception
            when Core.Identity.Not_A_Git_Repo =>
               Complain (Env, Prog & ": not inside a git repo" & ASCII.LF);
               return (Found => False);

            when Core.Identity.Detached_Head =>
               Complain (Env, Core.Identity.Detached_Message & ASCII.LF);
               return (Found => False);

            when others =>
               Complain
                 (Env, Prog & ": could not resolve the namespace" & ASCII.LF);
               return (Found => False);
         end;
      end if;

      Result.Vault     := Vault.Path;
      Result.Namespace :=
        To_Unbounded_String
          (Value_Or
             (Non_Empty (Env, "SYNAPSE_NAMESPACE"), To_String (Resolved.Key)));
      Result.Repo_Root :=
        To_Unbounded_String
          (Value_Or
             (Non_Empty (Env, "SYNAPSE_REPO_ROOT"),
              To_String (Resolved.Where.Repo_Root)));
      Result.Branch    :=
        To_Unbounded_String
          (Value_Or
             (Non_Empty (Env, "SYNAPSE_BRANCH"),
              To_String (Resolved.Branch_Key)));
      --  Compared with the index's own field: absent must mismatch and not
      --  pass by comparing empty with empty.
      Result.Remote    :=
        To_Unbounded_String
          (Value_Or
             (Non_Empty (Env, "SYNAPSE_REMOTE"), To_String (Resolved.Remote)));
      Result.Work_Dir  :=
        To_Unbounded_String (Work_Dir_For (Env, To_String (Result.Namespace)));
      Result.Dir       :=
        To_Unbounded_String ("synapse/" & To_String (Result.Namespace));
      Result.Abs_Dir   :=
        To_Unbounded_String
          (To_String (Result.Vault) & "/" & To_String (Result.Dir));
      Load_Chains (Env, Result);
      return (Found => True, Item => Result);
   end Resolve;

   function Resolve_Explicit
     (Env : Environment; Prog : String; Namespace : String)
      return Maybe_Context
   is
      Vault   : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Vault_Dir (Env.Vars.all);
      Result  : Context;
      At_Sign : Natural                                 := 0;
   begin
      if not Vault.Found then
         Complain (Env, Prog & ": no vault" & ASCII.LF);
         return (Found => False);
      end if;
      for I in Namespace'Range loop
         if Namespace (I) = '@' then
            At_Sign := I;
            exit;
         end if;
      end loop;
      if At_Sign = 0 then
         Complain
           (Env,
            Prog & ": --namespace expects <repo>@<branch>, got '" & Namespace &
            "'" & ASCII.LF);
         return (Found => False);
      end if;
      Result.Vault              := Vault.Path;
      Result.Namespace          := To_Unbounded_String (Namespace);
      Result.Repo_Root          :=
        To_Unbounded_String
          (Value_Or (Non_Empty (Env, "SYNAPSE_REPO_ROOT"), ""));
      Result.Branch             :=
        To_Unbounded_String (Namespace (At_Sign + 1 .. Namespace'Last));
      Result.Work_Dir := To_Unbounded_String (Work_Dir_For (Env, Namespace));
      Result.Namespace_Explicit := True;
      Result.Dir := To_Unbounded_String ("synapse/" & Namespace);
      Result.Abs_Dir            :=
        To_Unbounded_String
          (To_String (Result.Vault) & "/" & To_String (Result.Dir));
      Load_Chains (Env, Result);
      return (Found => True, Item => Result);
   end Resolve_Explicit;

   function Field_Of (Text, Key : String) return String is
      Got : constant Core.Node_Query.Maybe_Text :=
        Core.Node_Query.Field (Text, Key);
   begin
      return (if Got.Found then To_String (Got.Text) else "");
   end Field_Of;

   function Verify_Namespace
     (Env : Environment; Ctx : Context; Prog : String) return Boolean
   is
      Path : constant String := To_String (Ctx.Abs_Dir) & "/Index.md";
   begin
      declare
         Text : constant String := Files.Read (Path, 64 * 1_024 * 1_024);
      begin
         --  An explicit namespace has no remote of the current directory to
         --  agree with.
         if not Ctx.Namespace_Explicit
           and then Field_Of (Text, "remote") /= To_String (Ctx.Remote)
         then
            return False;
         end if;
         if Field_Of (Text, "branch") /= To_String (Ctx.Branch) then
            Complain
              (Env,
               Prog & ": " & To_String (Ctx.Dir) & "/ records branch '" &
               Field_Of (Text, "branch") & "', not '" &
               To_String (Ctx.Branch) & "'" & ASCII.LF);
            return False;
         end if;
         return True;
      end;
   exception
      when others =>
         Complain
           (Env,
            Prog & ": no namespace covers " & To_String (Ctx.Dir) &
            "/ -- this branch has no graph" & ASCII.LF);
         return False;
   end Verify_Namespace;

   function Strip_Md (Name : String) return String is
     (if Name'Length >= 3 and then Name (Name'Last - 2 .. Name'Last) = ".md"
      then Name (Name'First .. Name'Last - 3)
      else Name);

   function Node_Path (Ctx : Context; Name : String) return String is
     (To_String (Ctx.Abs_Dir) & "/" &
      (if Name'Length >= 3 and then Name (Name'Last - 2 .. Name'Last) = ".md"
       then Name
       else Name & ".md"));

   function Read_Node (Ctx : Context; Name : String) return Maybe_Text is
   begin
      return
        (Found => True,
         Text  =>
           To_Unbounded_String
             (Files.Read (Node_Path (Ctx, Name), 256 * 1_024 * 1_024)));
   exception
      when others =>
         return (Found => False);
   end Read_Node;

end Synapse.Commands.Context;
