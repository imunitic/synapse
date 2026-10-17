with Ada.Strings.Unbounded;

--  `stop-nudge`: Stop. Every 25 turns, a check-in on whether the session
--  produced something worth keeping in the vault. It is context and not a
--  block, which Claude Code labels as feedback and not as an error.
--
--  Vault sync is not driven from here: a git-backed vault commits from
--  inside its store's write and pushes on its own threshold. `Pull` runs once
--  per session, started detached by `session-start`.
package Synapse.Hooks.Stop_Nudge is

   procedure Run (Env : Environment);

   type Tick_Result is record
      --  The nudge, when this call just re-armed it.
      Nudge : Ada.Strings.Unbounded.Unbounded_String;
      Due   : Boolean := False;
      --  The turns counted so far in this session.
      Total : Natural := 0;
   end record;

   --  Counts a turn of the session Sid in the home's state directory and says
   --  whether a check-in is due.
   function Tick (Env : Environment; Home, Sid : String) return Tick_Result;

   --  `synapse-hook vault-pull`: brings a git-backed vault up to date. Not
   --  registered as a hook: `session-start` runs it detached, so a turn never
   --  waits on the network. Nothing when the vault is not git-backed, even
   --  with a stray `.git` in its folder: the choice of backend is the
   --  opt-in. It shares the git store's lock for a short bounded wait, so a
   --  write in flight is not raced; that round is skipped instead.
   procedure Pull (Env : Environment);

   --  Starts `Pull` as a detached copy of this program.
   procedure Spawn_Pull (Env : Environment);

end Synapse.Hooks.Stop_Nudge;
