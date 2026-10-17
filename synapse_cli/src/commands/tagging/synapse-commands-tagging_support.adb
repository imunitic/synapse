with Ada.IO_Exceptions;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Tree_Sitter.Preparation;
with Synapse.Ports.Variables;

package body Synapse.Commands.Tagging_Support is

   use Ada.Strings.Unbounded;

   Largest_Conf : constant := 8 * 1_024 * 1_024;

   function Variable (Env : Environment; Name : String) return String is
      Got : constant Ports.Variables.Maybe_Value := Env.Vars.Get (Name);
   begin
      return (if Got.Found then To_String (Got.Value) else "");
   end Variable;

   --  The text of Path, or empty and false when it is missing; raises for a
   --  file that is there and cannot be read.
   procedure Read_Conf
     (Path : String; Text : out Unbounded_String; Present : out Boolean)
   is
   begin
      Text    :=
        To_Unbounded_String (Adapters.File_Bytes.Read (Path, Largest_Conf));
      Present := True;
   exception
      when Ada.IO_Exceptions.Name_Error =>
         Text    := Null_Unbounded_String;
         Present := False;
   end Read_Conf;

   procedure Load_Registry
     (Env  :     Environment; Registry : out Core.Grammar_Registry.Registry;
      Path : out Unbounded_String; Status : out Load_Status)
   is
      Found   : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Resolve_Conf_Path
          (Env.Vars.all, "synapse-grammars.conf");
      Text    : Unbounded_String;
      Present : Boolean;
   begin
      Path     := Null_Unbounded_String;
      Registry := Core.Grammar_Registry.Parse ("{}");
      if not Env.Vars.Get ("HOME").Found then
         Status := No_Home;
         return;
      end if;
      Path :=
        (if Found.Found then Found.Value
         else To_Unbounded_String
             (Variable (Env, "HOME") & "/.claude/synapse-grammars.conf"));
      Read_Conf (To_String (Path), Text, Present);
      if Present then
         Registry := Core.Grammar_Registry.Parse (To_String (Text));
      end if;
      Status := Loaded;
   exception
      when Core.Grammar_Registry.Malformed | Ada.IO_Exceptions.Use_Error
        | Ada.IO_Exceptions.Data_Error | Adapters.File_Bytes.Too_Large =>
         Status := Unreadable;
   end Load_Registry;

   procedure Load_Rules
     (Env  :     Environment; Rules : out Core.Kind_Synonyms.Rule_List;
      Path : out Unbounded_String; Status : out Load_Status)
   is
      Configured : constant String                         :=
        Variable (Env, "SYNAPSE_KIND_SYNONYMS_CONF");
      Found      : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Resolve_Conf_Path
          (Env.Vars.all, "synapse-kind-synonyms.conf");
      Text       : Unbounded_String;
      Present    : Boolean;
   begin
      Path  := Null_Unbounded_String;
      Rules := Core.Kind_Synonyms.Parse ("[]");
      if Env.Vars.Get ("SYNAPSE_KIND_SYNONYMS_CONF").Found then
         Path := To_Unbounded_String (Configured);
      elsif Found.Found then
         Path := Found.Value;
      elsif Env.Vars.Get ("HOME").Found then
         Path :=
           To_Unbounded_String
             (Variable (Env, "HOME") & "/.claude/synapse-kind-synonyms.conf");
      else
         Status := No_Home;
         return;
      end if;
      Read_Conf (To_String (Path), Text, Present);
      if Present then
         Rules := Core.Kind_Synonyms.Parse (To_String (Text));
      end if;
      Status := Loaded;
   exception
      when Core.Kind_Synonyms.Malformed | Ada.IO_Exceptions.Use_Error
        | Ada.IO_Exceptions.Data_Error | Adapters.File_Bytes.Too_Large =>
         Status := Unreadable;
   end Load_Rules;

   procedure Grammars_Dir
     (Env : Environment; Dir : out Unbounded_String; Found : out Boolean)
   is
      Named : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Resolve (Env.Vars.all, "SYNAPSE_GRAMMARS_DIR");
   begin
      Found := True;
      if Named.Found then
         Dir := Named.Value;
      elsif Env.Vars.Get ("HOME").Found then
         Dir :=
           To_Unbounded_String
             (Variable (Env, "HOME") & "/.cache/synapse/grammars");
      else
         Dir   := Null_Unbounded_String;
         Found := False;
      end if;
   end Grammars_Dir;

   function Settings_For
     (Env : Environment; Registry : Core.Grammar_Registry.Registry;
      Dir : String; Rules : Core.Kind_Synonyms.Rule_List)
      return Synapse.Ports.Extractor_Factory.Settings
   is
      Tries  : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Resolve
          (Env.Vars.all, "SYNAPSE_GRAMMAR_LOCK_TRIES");
      Query  : constant Adapters.Conf_Files.Maybe_Path :=
        Adapters.Conf_Files.Resolve
          (Env.Vars.all, "SYNAPSE_GRAMMARS_QUERY_PATH");
      Result : Synapse.Ports.Extractor_Factory.Settings;
   begin
      Result.Registry     := Registry;
      Result.Grammars_Dir := To_Unbounded_String (Dir);
      Result.Rules        := Rules;
      Result.Max_Tries := Adapters.Tree_Sitter.Preparation.Default_Lock_Tries;
      if Tries.Found then
         declare
            Raw : constant String := To_String (Tries.Value);
         begin
            if Raw'Length > 0 and then (for all C of Raw => C in '0' .. '9')
              and then Natural'Value (Raw) > 0
            then
               Result.Max_Tries := Natural'Value (Raw);
            end if;
         exception
            when Constraint_Error =>
               null;
         end;
      end if;
      if Query.Found then
         Result.Override_Dir := (Found => True, Value => Query.Value);
      end if;
      return Result;
   end Settings_For;

end Synapse.Commands.Tagging_Support;
