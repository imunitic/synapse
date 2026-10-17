with Ada.Directories;

with Synapse.Adapters.Dir_Lock;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Git_Sync;
with Synapse.Adapters.Replace_File;
with Synapse.Adapters.Store_Resolve;
with Synapse.Adapters.System_Spawner;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Timestamps;
with Synapse.Hooks.Common;
with Synapse.Ports.Variables;

package body Synapse.Hooks.Stop_Nudge is

   use Ada.Strings.Unbounded;

   package Image renames Synapse.Core.Decimal_Image;

   LF : constant Character := Character'Val (10);

   --  Turns between check-ins.
   N : constant Natural := 25;

   --  The heading of `synapse-claude.md` the nudge points at, named once.
   Vault_Note_Heading : constant String := "Synapse Vault as permanent memory";

   function Read_Count (Env : Environment; Path : String) return Natural is
   begin
      if not Ada.Directories.Exists (Path) then
         return 0;
      end if;
      declare
         Text  : constant String := Adapters.File_Bytes.Read (Path, 64);
         First : Natural         := Text'First;
         Last  : Natural         := Text'Last;
      begin
         while First <= Last
           and then Text (First) in ' ' | ASCII.HT | ASCII.CR | LF
         loop
            First := First + 1;
         end loop;
         while Last >= First
           and then Text (Last) in ' ' | ASCII.HT | ASCII.CR | LF
         loop
            Last := Last - 1;
         end loop;
         return Natural'Value (Text (First .. Last));
      exception
         when Constraint_Error =>
            Complain
              (Env,
               "synapse-hook: corrupt stop-nudge counter, restarting from 0 (" &
               Path & ")" & LF);
            return 0;
      end;
   exception
      when others =>
         Complain
           (Env,
            "synapse-hook: unreadable stop-nudge counter, restarting from 0 (" &
            Path & ")" & LF);
         return 0;
   end Read_Count;

   --  Through a temporary file and a rename: a process killed mid-write
   --  leaves the old count and not a truncated one.
   procedure Write_Count (Env : Environment; Path : String; Value : Natural) is
      Tmp : constant String := Path & ".tmp";
   begin
      Adapters.File_Bytes.Write (Tmp, Image.Image (Value) & LF);
      Adapters.Replace_File.Replace (Tmp, Path);
   exception
      when others =>
         Complain
           (Env,
            "synapse-hook: could not write the stop-nudge counter, it may " &
            "not fire on schedule (" & Path & ")" & LF);
   end Write_Count;

   function Tick (Env : Environment; Home, Sid : String) return Tick_Result is
      State_Dir  : constant String := Home & "/.claude/state";
      Total_Path : constant String :=
        State_Dir & "/synapse-stop-nudge-total-" & Sid;
      Since_Path : constant String :=
        State_Dir & "/synapse-stop-nudge-since-" & Sid;
      Result     : Tick_Result;
   begin
      begin
         Ada.Directories.Create_Path (State_Dir);
      exception
         when others =>
            null;
      end;
      declare
         Total : constant Natural := Read_Count (Env, Total_Path) + 1;
         Since : constant Natural := Read_Count (Env, Since_Path) + 1;
      begin
         Write_Count (Env, Total_Path, Total);
         Result.Total := Total;
         if Since >= N then
            Write_Count (Env, Since_Path, 0);
            declare
               Vault    : constant Common.Maybe_Text := Common.Vault (Env);
               Location : constant String            :=
                 (if Vault.Found then To_String (Vault.Value)
                  else "the vault");
            begin
               Result.Due   := True;
               Result.Nudge :=
                 To_Unbounded_String
                   ("This session has grown substantial (" &
                    Image.Image (Total) & " turns, re-armed at the " &
                    Image.Image (N) & "-turn mark). Before continuing: did " &
                    "this session produce a debugging/investigation/" &
                    "research finding, decision, or piece of context worth " &
                    "persisting to Synapse Vault (" & Location & ")? If so, " &
                    "write it up now (see the global CLAUDE.md """ &
                    Vault_Note_Heading & """ section, or use /synapse-note) " &
                    "while full context is still available -- do not wait " &
                    "for a wrap-up step. If you already wrote or updated a " &
                    "note earlier this session, check whether anything " &
                    "since then is worth folding in too.");
            end;
         else
            Write_Count (Env, Since_Path, Since);
         end if;
      end;
      return Result;
   end Tick;

   procedure Run (Env : Environment) is
      Home : constant Ports.Variables.Maybe_Value := Env.Vars.Get ("HOME");
   begin
      if not Home.Found then
         return;
      end if;
      declare
         Payload : constant Common.Payload    := Common.Read (Env);
         Sid     : constant Common.Maybe_Text :=
           Common.Str (Payload, "session_id");
         Done    : constant Tick_Result       :=
           Tick
             (Env, To_String (Home.Value),
              (if Sid.Found then To_String (Sid.Value) else "default"));
      begin
         if Done.Due then
            Common.Emit_Context (Env, "Stop", To_String (Done.Nudge));
         end if;
      end;
   end Run;

   --  One failure line in the vault's own sync log, never shown to a turn:
   --  someone debugging a vault that stopped pulling finds it there.
   procedure Append_Sync_Failure (Env : Environment; Vault : String) is
      Log      : constant String := Vault & "/.git/synapse-sync.log";
      Stamp    : constant String :=
        Core.Timestamps.Built_At (Env.Clock.Timestamp);
      Existing : constant String :=
        (if Ada.Directories.Exists (Log) then
           Adapters.File_Bytes.Read (Log, 16 * 1_024 * 1_024)
         else "");
   begin
      Adapters.File_Bytes.Write
        (Log, Existing & Stamp & " pull failed, vault left as it was" & LF);
   exception
      when others =>
         Complain
           (Env,
            "synapse-hook: pull failed, and could not even log it to the " &
            "sync log" & LF);
   end Append_Sync_Failure;

   procedure Pull (Env : Environment) is
      Vault : constant Common.Maybe_Text := Common.Vault (Env);
   begin
      if not Vault.Found
        or else not Adapters.Store_Resolve.Has_Integration
          (Env.Vars.all, "git")
      then
         return;
      end if;
      declare
         Where : constant String := To_String (Vault.Value);
         Lock  : Adapters.Dir_Lock.Lock;
      begin
         Adapters.Git_Sync.Acquire_With_Retry (Where, 5, Lock);
         if not Adapters.Dir_Lock.Held (Lock) then
            return;
         end if;
         if not Adapters.Git_Sync.Pull (Env.Runner.all, Where) then
            Append_Sync_Failure (Env, Where);
         end if;
         Adapters.Dir_Lock.Release (Lock);
      end;
   end Pull;

   --  Unthrottled, since a session start is infrequent and freshness at its
   --  very start is the point.
   procedure Spawn_Pull (Env : Environment) is
      Program : constant String := To_String (Env.Argv0);
      Success : Boolean;
   begin
      if Program = "" then
         return;
      end if;
      Adapters.System_Spawner.Spawn_Detached
        (Program, "vault-pull", "", Success);
      if not Success then
         Complain (Env, "synapse-hook: could not spawn vault-pull" & LF);
      end if;
   end Spawn_Pull;

end Synapse.Hooks.Stop_Nudge;
