with Ada.Strings.Unbounded;

with Synapse.Adapters.Git_Sync;
with Synapse.Adapters.System_Spawner;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Vault_Support;
with Synapse.Commands.Vault_Usage;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Patch;
with Synapse.Ports.Store;

package body Synapse.Commands.Vault_Write is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.Patch.Operation;

   package Port renames Synapse.Ports.Store;
   package Support renames Synapse.Commands.Vault_Support;

   Prog : constant String    := "synapse-vault";
   LF   : constant Character := Character'Val (10);

   --  Stores Text as the note Path, and says what came of it: the path on
   --  success, why not otherwise.
   function Store_Note
     (Env  : Environment; Stack : in out Support.Store_Resolve.Stack;
      Path : String; Text : String) return Boolean
   is
   begin
      declare
         Wrote : constant Port.Write_Result :=
           Support.Store_Resolve.Store (Stack).Write (Path, Text);
      begin
         if not Wrote.Accepted then
            Complain
              (Env,
               Prog & ": write rejected (" &
               Core.Decimal_Image.Image (Wrote.Status) & "): " &
               To_String (Wrote.Body_Text) & LF);
            return False;
         end if;
         return True;
      end;
   exception
      when Port.Store_Failure | Port.Unsafe_Node | Port.Node_Not_Found =>
         Complain (Env, Prog & ": write failed" & LF);
         return False;
   end Store_Note;

   function Run_Write (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Path    : Unbounded_String;
      Done    : Boolean;
      Code    : Exit_Code;
      Vault   : Unbounded_String;
      Found   : Boolean;
      Stack   : Support.Store_Resolve.Stack;
      Ok      : Boolean;
      Spawner : aliased Adapters.System_Spawner.System_Spawner :=
        (Program => Env.Argv0);
   begin
      Support.One_Path (Env, Args, Vault_Usage.Write, Path, Done, Code);
      if Done then
         return Code;
      end if;
      Support.Find_Vault (Env, Prog, Vault, Found);
      if not Found then
         return 1;
      end if;
      declare
         Text : constant String := Env.Console.Read_Stdin;
      begin
         Support.Open
           (Env, Prog, To_String (Vault), Stack, Ok, Spawner'Access);
         if not Ok then
            return 1;
         end if;
         if not Store_Note (Env, Stack, To_String (Path), Text) then
            return 1;
         end if;
         Say (Env, To_String (Path) & LF);
         return 0;
      end;
   end Run_Write;

   --  The `::` separated words of a heading path, empty ones kept.
   function Segments (Raw : String) return Lists.Vector is
      Result : Lists.Vector;
      Start  : Positive := Raw'First;
      I      : Natural  := Raw'First;
   begin
      while I <= Raw'Last loop
         if Raw (I) = ':' and then I < Raw'Last and then Raw (I + 1) = ':' then
            Result.Append (To_Unbounded_String (Raw (Start .. I - 1)));
            I     := I + 2;
            Start := I;
         else
            I := I + 1;
         end if;
      end loop;
      Result.Append (To_Unbounded_String (Raw (Start .. Raw'Last)));
      return Result;
   end Segments;

   type Parsing is (Parsed, Help_Asked, Bad_Usage);

   type Patch_Request is record
      Outcome : Parsing              := Bad_Usage;
      Path    : Unbounded_String;
      Where   : Core.Patch.Target;
      Op      : Core.Patch.Operation := Core.Patch.Replace;
      Create  : Boolean              := False;
   end record;

   --  What the arguments of vault-patch ask for. A flag naming the target
   --  takes its value after it, and only one target is named.
   function Parse_Patch (Args : Lists.Vector) return Patch_Request is
      Result      : Patch_Request;
      Have_Target : Boolean  := False;
      I           : Positive := 2;

      function Takes_Value return Boolean is
        (not Have_Target and then I < Natural (Args.Length));
   begin
      if Args.Is_Empty then
         return Result;
      end if;
      if Cli_Args.Is_Help (To_String (Args (1))) then
         Result.Outcome := Help_Asked;
         return Result;
      end if;
      Result.Path := Args (1);
      while I <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Cli_Args.Is_Help (Arg) then
               Result.Outcome := Help_Asked;
               return Result;
            elsif Arg in "--heading" | "--block" | "--frontmatter" then
               if not Takes_Value then
                  return (Outcome => Bad_Usage, others => <>);
               end if;
               I            := I + 1;
               Result.Where :=
                 (if Arg = "--heading" then
                    (Kind => Core.Patch.Heading,
                     Path => Segments (To_String (Args (I))))
                  elsif Arg = "--block" then
                    (Kind => Core.Patch.Block_Id, Name => Args (I))
                  else (Kind => Core.Patch.Frontmatter_Key, Name => Args (I)));
               Have_Target  := True;
            elsif Arg = "--append" then
               Result.Op := Core.Patch.Append;
            elsif Arg = "--prepend" then
               Result.Op := Core.Patch.Prepend;
            elsif Arg = "--replace" then
               Result.Op := Core.Patch.Replace;
            elsif Arg = "--rename-heading" then
               Result.Op := Core.Patch.Rename;
            elsif Arg = "--create" then
               Result.Create := True;
            else
               return (Outcome => Bad_Usage, others => <>);
            end if;
         end;
         I := I + 1;
      end loop;
      Result.Outcome := (if Have_Target then Parsed else Bad_Usage);
      return Result;
   end Parse_Patch;

   function Patch_Message
     (Kind : Core.Patch.Error_Kind; Path : String) return String is
     (case Kind is
        when Core.Patch.Target_Not_Found =>
          Prog & ": target not found in " & Path,
        when Core.Patch.No_Frontmatter => Prog & ": no frontmatter in " & Path,
        when Core.Patch.Invalid_Operation_For_Target =>
          Prog & ": --rename-heading only applies to --heading",
        when Core.Patch.Multiline_Heading_Text =>
          Prog & ": a heading's new text must be a single line",
        when Core.Patch.Too_Large => Prog & ": patch failed");

   function Run_Patch (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Wanted  : constant Patch_Request := Parse_Patch (Args);
      Vault   : Unbounded_String;
      Found   : Boolean;
      Stack   : Support.Store_Resolve.Stack;
      Ok      : Boolean;
      Spawner : aliased Adapters.System_Spawner.System_Spawner :=
        (Program => Env.Argv0);
   begin
      case Wanted.Outcome is
         when Bad_Usage =>
            return Usage_Error (Env, Vault_Usage.Patch);

         when Help_Asked =>
            Complain (Env, Vault_Usage.Patch);
            return 0;

         when Parsed =>
            null;
      end case;
      Support.Find_Vault (Env, Prog, Vault, Found);
      if not Found then
         return 1;
      end if;
      declare
         Content : constant String := Env.Console.Read_Stdin;
         Path    : constant String := To_String (Wanted.Path);
      begin
         Support.Open
           (Env, Prog, To_String (Vault), Stack, Ok, Spawner'Access);
         if not Ok then
            return 1;
         end if;
         declare
            Current : constant Port.Maybe_Text :=
              Support.Store_Resolve.Store (Stack).Read (Path);
         begin
            if not Current.Found then
               Complain (Env, Prog & ": no such note: " & Path & LF);
               return 1;
            end if;
            declare
               Patched : constant Core.Patch.Results.Result :=
                 Core.Patch.Apply
                   (To_String (Current.Value), Wanted.Where, Wanted.Op,
                    Content, Wanted.Create);
            begin
               if not Core.Patch.Results.Is_Success (Patched) then
                  Complain
                    (Env,
                     Patch_Message (Core.Patch.Results.Error (Patched), Path) &
                     LF);
                  return 1;
               end if;
               if not Store_Note
                   (Env, Stack, Path,
                    To_String (Core.Patch.Results.Value (Patched)))
               then
                  return 1;
               end if;
            end;
         end;
         Say (Env, Path & LF);
         if Wanted.Op = Core.Patch.Rename then
            --  Everything under the heading now lives under its new path.
            declare
               Segs     : constant Lists.Vector := Wanted.Where.Path;
               Out_Text : Unbounded_String;
            begin
               for K in 1 .. Natural (Segs.Length) - 1 loop
                  Append (Out_Text, Segs (K));
                  Append (Out_Text, "::");
               end loop;
               Append (Out_Text, Content & LF);
               Say (Env, To_String (Out_Text));
            end;
         end if;
         return 0;
      end;
   exception
      when Port.Store_Failure | Port.Unsafe_Node | Port.Node_Not_Found =>
         Complain (Env, Prog & ": read failed" & LF);
         return 1;
   end Run_Patch;

   function Run_Rename
     (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Vault : Unbounded_String;
      Found : Boolean;
      Stack : Support.Store_Resolve.Stack;
      Ok    : Boolean;
   begin
      if Args.Is_Empty then
         return Usage_Error (Env, Vault_Usage.Rename);
      end if;
      if Cli_Args.Is_Help (To_String (Args (1))) then
         Complain (Env, Vault_Usage.Rename);
         return 0;
      end if;
      if Natural (Args.Length) /= 2 then
         return Usage_Error (Env, Vault_Usage.Rename);
      end if;
      Support.Find_Vault (Env, Prog, Vault, Found);
      if not Found then
         return 1;
      end if;
      Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
      if not Ok then
         return 1;
      end if;
      declare
         Old_Path : constant String := To_String (Args (1));
         New_Path : constant String := To_String (Args (2));
      begin
         Support.Store_Resolve.Renamer (Stack).Rename (Old_Path, New_Path);
         Say (Env, New_Path & LF);
         return 0;
      exception
         when Port.Node_Not_Found                   =>
            Complain (Env, Prog & ": no such note: " & Old_Path & LF);
            return 1;
         when Port.Store_Failure | Port.Unsafe_Node =>
            Complain (Env, Prog & ": rename failed" & LF);
            return 1;
      end;
   end Run_Rename;

   function Run_Delete
     (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Path  : Unbounded_String;
      Done  : Boolean;
      Code  : Exit_Code;
      Vault : Unbounded_String;
      Found : Boolean;
      Stack : Support.Store_Resolve.Stack;
      Ok    : Boolean;
   begin
      Support.One_Path (Env, Args, Vault_Usage.Delete, Path, Done, Code);
      if Done then
         return Code;
      end if;
      Support.Find_Vault (Env, Prog, Vault, Found);
      if not Found then
         return 1;
      end if;
      Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
      if not Ok then
         return 1;
      end if;
      begin
         Support.Store_Resolve.Deleter (Stack).Delete (To_String (Path));
         Say (Env, To_String (Path) & LF);
         return 0;
      exception
         when Port.Node_Not_Found                   =>
            Complain (Env, Prog & ": no such note: " & To_String (Path) & LF);
            return 1;
         when Port.Store_Failure | Port.Unsafe_Node =>
            Complain (Env, Prog & ": delete failed" & LF);
            return 1;
      end;
   end Run_Delete;

   function Run_Git_Pusher
     (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
   begin
      if Args.Is_Empty then
         return 2;
      end if;
      Adapters.Git_Sync.Run_Pusher (Env.Runner.all, To_String (Args (1)));
      return 0;
   end Run_Git_Pusher;

end Synapse.Commands.Vault_Write;
