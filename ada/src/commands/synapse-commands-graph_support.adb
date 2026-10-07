with Ada.Directories;
with Ada.IO_Exceptions;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Git_Identity;
with Synapse.Commands.Context;
with Synapse.Core.Identity;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Variables;

package body Synapse.Commands.Graph_Support is

   use Ada.Strings.Unbounded;

   package Runner_Port renames Synapse.Ports.Process_Runner;

   function Set_Variable (Env : Environment; Name : String) return String is
      Got : constant Synapse.Ports.Variables.Maybe_Value :=
        Env.Vars.Get (Name);
   begin
      return (if Got.Found then To_String (Got.Value) else "");
   end Set_Variable;

   function Work_Dir
     (Env : Environment; Prog : String; Repo : String := ".") return Maybe_Path
   is
      Configured : constant String := Set_Variable (Env, "SYNAPSE_WORK_DIR");
      Namespace  : constant String := Set_Variable (Env, "SYNAPSE_NAMESPACE");
   begin
      if Configured /= "" then
         return (Found => True, Value => To_Unbounded_String (Configured));
      end if;
      declare
         Key : Unbounded_String;
      begin
         if Namespace /= "" then
            Key := To_Unbounded_String (Namespace);
         else
            begin
               Key := Adapters.Git_Identity.Resolve (Repo).Key;
            exception
               when Core.Identity.Not_A_Git_Repo =>
                  Complain (Env, Prog & ": not inside a git repo" & ASCII.LF);
                  return (Found => False);

               when Core.Identity.Detached_Head =>
                  Complain (Env, Core.Identity.Detached_Message & ASCII.LF);
                  return (Found => False);

               when others =>
                  Complain
                    (Env,
                     Prog & ": could not resolve the namespace" & ASCII.LF);
                  return (Found => False);
            end;
         end if;
         if not Env.Vars.Get ("HOME").Found then
            Complain
              (Env, Prog & ": no HOME, so no default work dir" & ASCII.LF);
            return (Found => False);
         end if;
         return
           (Found => True,
            Value =>
              To_Unbounded_String
                (Set_Variable (Env, "HOME") & "/.cache/synapse/work/" &
                 To_String (Key)));
      end;
   end Work_Dir;

   function Work_Dir_For_Namespace
     (Env : Environment; Namespace : String; Prog : String) return Maybe_Path
   is
      Configured : constant String := Set_Variable (Env, "SYNAPSE_WORK_DIR");
   begin
      if (for all C of Namespace => C /= '@') then
         Complain
           (Env,
            Prog & ": --namespace expects <repo>@<branch>, got '" & Namespace &
            "'" & ASCII.LF);
         return (Found => False);
      end if;
      if Configured /= "" then
         return (Found => True, Value => To_Unbounded_String (Configured));
      end if;
      if not Env.Vars.Get ("HOME").Found then
         Complain (Env, Prog & ": no HOME, so no default work dir" & ASCII.LF);
         return (Found => False);
      end if;
      return
        (Found => True,
         Value => To_Unbounded_String (Context.Work_Dir_For (Env, Namespace)));
   end Work_Dir_For_Namespace;

   function Repo_Root (Env : Environment; Repo : String) return String is
      Args : Lists.Vector;
      Ran  : Runner_Port.Result;
   begin
      Args.Append (To_Unbounded_String ("rev-parse"));
      Args.Append (To_Unbounded_String ("--show-toplevel"));
      Ran :=
        Env.Runner.Run
          ("git", Args,
           (Cwd   => To_Unbounded_String (Repo), Has_Stdin => False,
            Stdin => Null_Unbounded_String));
      if Ran.Exit_Code /= 0 then
         return "";
      end if;
      declare
         Text  : constant String := To_String (Ran.Output);
         First : Positive        := Text'First;
         Last  : Natural         := Text'Last;
      begin
         while First <= Last
           and then Text (First) in ' ' | ASCII.HT | ASCII.CR | ASCII.LF
         loop
            First := First + 1;
         end loop;
         while Last >= First
           and then Text (Last) in ' ' | ASCII.HT | ASCII.CR | ASCII.LF
         loop
            Last := Last - 1;
         end loop;
         return Text (First .. Last);
      end;
   exception
      when Runner_Port.Process_Failure =>
         return "";
   end Repo_Root;

   function Has_Usable_Extension
     (Path : String; Usable : Lists.Vector) return Boolean
   is
      Name_First : Positive := Path'First;
      Dot        : Natural := 0;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            Name_First := I + 1;
            exit;
         end if;
      end loop;
      for I in reverse Name_First .. Path'Last loop
         if Path (I) = '.' then
            Dot := I;
            exit;
         end if;
      end loop;
      if Dot = 0 or else Dot = Name_First then
         return False;
      end if;
      return
        Usable.Contains (To_Unbounded_String (Path (Dot + 1 .. Path'Last)));
   end Has_Usable_Extension;

   procedure Load_Rule_Registry
     (Env : Environment; Variable_Name, Conf_Name : String;
      Rules : out Core.Namespace.Registry; Ok : out Boolean)
   is
      Found : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Resolve_Conf_Path (Env.Vars.all, Conf_Name);
      Named : constant Synapse.Ports.Variables.Maybe_Value :=
        Env.Vars.Get (Variable_Name);
      Path  : constant String :=
        (if Named.Found then To_String (Named.Value)
         elsif Found.Found then To_String (Found.Value)
         else Set_Variable (Env, "HOME") & "/.claude/" & Conf_Name);
      Text  : Unbounded_String;
      Read  : Boolean;
   begin
      Rules := Core.Namespace.Parse ("{}");
      Ok := True;
      Read_File (Path, 8 * 1_024 * 1_024, Text, Read);
      if Read then
         Rules := Core.Namespace.Parse (To_String (Text));
      elsif Ada.Directories.Exists (Path) then
         Ok := False;
      end if;
   exception
      when Core.Namespace.Malformed =>
         Ok := False;
   end Load_Rule_Registry;

   function Max_Listing_Bytes
     (Env : Environment; Default : Natural) return Natural
   is
      Raw : constant String := Set_Variable (Env, "SYNAPSE_MAX_LISTING_BYTES");
   begin
      if Raw = "" or else not (for all C of Raw => C in '0' .. '9') then
         return Default;
      end if;
      return Natural'Value (Raw);
   exception
      when Constraint_Error =>
         return Natural'Last;
   end Max_Listing_Bytes;

   procedure Read_File
     (Path  :     String; Limit : Natural; Text : out Unbounded_String;
      Found : out Boolean)
   is
   begin
      Text  := To_Unbounded_String (Adapters.File_Bytes.Read (Path, Limit));
      Found := True;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
        | Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.End_Error
        | Ada.IO_Exceptions.Device_Error | Adapters.File_Bytes.Too_Large =>
         Text  := Null_Unbounded_String;
         Found := False;
   end Read_File;

   procedure Write_File (Path, Text : String) is
      Dir : constant String := Ada.Directories.Containing_Directory (Path);
   begin
      Ada.Directories.Create_Path (Dir);
      Adapters.File_Bytes.Write (Path, Text);
   end Write_File;

   procedure Grep
     (Env    :     Environment; Flag, Pattern, Input : String;
      Output : out Unbounded_String; Result : out Grep_Outcome)
   is
      Args : Lists.Vector;
      Ran  : Runner_Port.Result;
   begin
      Output := Null_Unbounded_String;
      Args.Append (To_Unbounded_String (Flag));
      Args.Append (To_Unbounded_String (Pattern));
      Ran    :=
        Env.Runner.Run
          ("grep", Args,
           (Cwd   => Null_Unbounded_String, Has_Stdin => True,
            Stdin => To_Unbounded_String (Input)));
      Output := Ran.Output;
      Result :=
        (case Ran.Exit_Code is when 0 => Matched, when 1 => Nothing_Matched,
           when others => Failed);
   exception
      when Runner_Port.Process_Failure =>
         Output := Null_Unbounded_String;
         Result := Failed;
   end Grep;

end Synapse.Commands.Graph_Support;
