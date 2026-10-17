with Ada.Directories;
with Ada.Strings.Fixed;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Git_Identity;
with Synapse.Core.Node_Query;
with Synapse.Ports.Variables;

package body Synapse.Hooks.Common is

   package J renames Synapse.Core.JSON;

   use type J.Kind;
   use type Ada.Directories.File_Kind;

   LF : constant Character := Character'Val (10);

   function Read (Env : Environment) return Payload is
      Text : constant String := Env.Console.Read_Stdin;
   begin
      if Text'Length = 0 then
         return (others => <>);
      end if;
      declare
         Parsed : constant J.Parse_Result := J.Parse (Text);
      begin
         if not Parsed.Ok or else J.Kind_Of (Parsed.Item) /= J.JSON_Object then
            return (others => <>);
         end if;
         return (Present => True, Root => Parsed.Item);
      end;
   end Read;

   function String_Member (V : J.Value; Key : String) return Maybe_Text is
   begin
      if J.Kind_Of (V) = J.JSON_Object and then J.Has_Member (V, Key) then
         declare
            Item : constant J.Value := J.Member_Value (V, Key);
         begin
            if J.Kind_Of (Item) = J.JSON_String
              and then J.As_String (Item)'Length > 0
            then
               return
                 (Found => True,
                  Value => To_Unbounded_String (J.As_String (Item)));
            end if;
         end;
      end if;
      return (Found => False);
   end String_Member;

   function Str (P : Payload; Key : String) return Maybe_Text is
     (if P.Present then String_Member (P.Root, Key) else (Found => False));

   function Nested (P : Payload; Outer, Inner : String) return Maybe_Text is
   begin
      if P.Present and then J.Has_Member (P.Root, Outer) then
         return String_Member (J.Member_Value (P.Root, Outer), Inner);
      end if;
      return (Found => False);
   end Nested;

   --  The path on the line after Marker, made absolute against the payload's
   --  `cwd` when it is not already.
   function After_Marker (P : Payload; Text, Marker : String) return Maybe_Text
   is
      At_Marker : constant Natural := Ada.Strings.Fixed.Index (Text, Marker);
   begin
      if At_Marker = 0 then
         return (Found => False);
      end if;
      declare
         Start : constant Positive := At_Marker + Marker'Length;
         Stop  : Natural           := Start;
      begin
         while Stop <= Text'Last and then Text (Stop) /= LF loop
            Stop := Stop + 1;
         end loop;
         declare
            Last : Natural := Stop - 1;
         begin
            while Last >= Start and then Text (Last) in ' ' | ASCII.CR loop
               Last := Last - 1;
            end loop;
            if Last < Start then
               return (Found => False);
            end if;
            declare
               Path : constant String     := Text (Start .. Last);
               Cwd  : constant Maybe_Text := Str (P, "cwd");
            begin
               if Path (Path'First) = '/' or else not Cwd.Found then
                  return (Found => True, Value => To_Unbounded_String (Path));
               end if;
               return
                 (Found => True,
                  Value => Cwd.Value & "/" & To_Unbounded_String (Path));
            end;
         end;
      end;
   end After_Marker;

   function Tool_File (P : Payload) return Maybe_Text is
      Direct   : constant Maybe_Text := Nested (P, "tool_input", "file_path");
      Response : constant Maybe_Text :=
        Nested (P, "tool_response", "filePath");
      Command  : constant Maybe_Text := Nested (P, "tool_input", "command");
   begin
      if Direct.Found then
         return Direct;
      elsif Response.Found then
         return Response;
      elsif not Command.Found then
         return (Found => False);
      end if;
      declare
         Text   : constant String     := To_String (Command.Value);
         Update : constant Maybe_Text :=
           After_Marker (P, Text, "*** Update File: ");
      begin
         if Update.Found then
            return Update;
         end if;
         return After_Marker (P, Text, "*** Add File: ");
      end;
   end Tool_File;

   function Vault (Env : Environment) return Maybe_Text is
      Dir : constant Maybe_Text :=
        Adapters.Conf_Files.Vault_Dir (Env.Vars.all);
   begin
      if Dir.Found and then Ada.Directories.Exists (To_String (Dir.Value))
        and then Ada.Directories.Kind (To_String (Dir.Value)) =
          Ada.Directories.Directory
      then
         return Dir;
      end if;
      return (Found => False);
   exception
      when others =>
         return (Found => False);
   end Vault;

   function Non_Empty (Env : Environment; Name : String) return Maybe_Text is
      Got : constant Ports.Variables.Maybe_Value := Env.Vars.Get (Name);
   begin
      if Got.Found and then Length (Got.Value) > 0 then
         return (Found => True, Value => Got.Value);
      end if;
      return (Found => False);
   end Non_Empty;

   function Resolve_Namespace
     (Env : Environment; Cwd : String) return Maybe_Namespace
   is
      Key    : constant Maybe_Text := Non_Empty (Env, "SYNAPSE_NAMESPACE");
      Root   : constant Maybe_Text := Non_Empty (Env, "SYNAPSE_REPO_ROOT");
      Branch : constant Maybe_Text := Non_Empty (Env, "SYNAPSE_BRANCH");
   begin
      if Key.Found and then Root.Found and then Branch.Found then
         --  An empty remote is a real configuration and not an absence.
         declare
            Remote : constant Ports.Variables.Maybe_Value :=
              Env.Vars.Get ("SYNAPSE_REMOTE");
         begin
            return
              (Found => True,
               Value =>
                 (Key    => Key.Value, Repo_Root => Root.Value,
                  Branch => Branch.Value,
                  Remote =>
                    (if Remote.Found then Remote.Value
                     else Null_Unbounded_String)));
         end;
      end if;
      declare
         Id : constant Core.Identity.Resolved :=
           Adapters.Git_Identity.Resolve (Cwd);
      begin
         return
           (Found => True,
            Value =>
              (Key    => Id.Key, Repo_Root => Id.Where.Repo_Root,
               Branch => Id.Branch_Key, Remote => Id.Remote));
      end;
   exception
      when others =>
         return (Found => False);
   end Resolve_Namespace;

   function Work_Dir (Env : Environment; Key : String) return Maybe_Text is
      Named : constant Maybe_Text := Non_Empty (Env, "SYNAPSE_WORK_DIR");
      Home  : constant Ports.Variables.Maybe_Value := Env.Vars.Get ("HOME");
   begin
      if Named.Found then
         return Named;
      elsif Home.Found then
         return
           (Found => True,
            Value =>
              Home.Value & "/.cache/synapse/work/" &
              To_Unbounded_String (Key));
      end if;
      return (Found => False);
   end Work_Dir;

   function Index_Agrees (Index_Text : String; Ns : Namespace) return Boolean
   is
      Remote : constant Core.Node_Query.Maybe_Text :=
        Core.Node_Query.Field (Index_Text, "remote");
      Branch : constant Core.Node_Query.Maybe_Text :=
        Core.Node_Query.Field (Index_Text, "branch");
   begin
      return
        Remote.Found and then Length (Remote.Value) > 0
        and then Remote.Value = Ns.Remote and then Branch.Found
        and then Length (Branch.Value) > 0 and then Branch.Value = Ns.Branch;
   end Index_Agrees;

   function Namespace_Matches (Vault : String; Ns : Namespace) return Boolean
   is
   begin
      return
        Index_Agrees
          (Adapters.File_Bytes.Read
             (Vault & "/synapse/" & To_String (Ns.Key) & "/Index.md",
              64 * 1_024 * 1_024),
           Ns);
   exception
      when others =>
         return False;
   end Namespace_Matches;

   function Json_String (Text : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("""");
      Hex    : constant String  := "0123456789abcdef";
   begin
      for C of Text loop
         case C is
            when '"' =>
               Append (Result, "\""");

            when '\' =>
               Append (Result, "\\");

            when LF =>
               Append (Result, "\n");

            when ASCII.CR =>
               Append (Result, "\r");

            when ASCII.HT =>
               Append (Result, "\t");

            when others =>
               if Character'Pos (C) < 16#20# then
                  Append
                    (Result,
                     "\u00" & Hex (Hex'First + Character'Pos (C) / 16) &
                     Hex (Hex'First + Character'Pos (C) mod 16));
               else
                  Append (Result, C);
               end if;
         end case;
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end Json_String;

   procedure Emit_Context (Env : Environment; Event, Text : String) is
   begin
      if Text'Length = 0 then
         return;
      end if;
      Say
        (Env,
         "{""hookSpecificOutput"":{""hookEventName"":" & Json_String (Event) &
         ",""additionalContext"":" & Json_String (Text) & "}}" & LF);
   end Emit_Context;

end Synapse.Hooks.Common;
