with Ada.Finalization;
with Ada.Strings.Unbounded;

--  A directory used as a lock: creating it is the atomic test-and-set. One
--  mechanism for everything that needs mutual exclusion over a file system
--  resource; each caller keeps its own path and its own staleness window.
--
--  A lock whose directory is older than the window is taken to be abandoned
--  by a process that died, and is stolen once.

package Synapse.Adapters.Dir_Lock is

   --  Holds the directory while Held; releases it when it goes out of scope,
   --  so an exception cannot leave a lock behind.
   type Lock is limited private;

   function Held (L : Lock) return Boolean;

   --  One attempt, never waiting: a caller on a write path cannot afford to.
   --  An existing directory older than Stale_After is removed and created
   --  once more; one that cannot be examined counts as not abandoned.
   procedure Try_Acquire
     (Path : String; Stale_After : Duration; L : in out Lock)
   with Pre => not Held (L);

   --  Try_Acquire up to Max_Tries times, 0.2 seconds apart.
   procedure Acquire_With_Retry
     (Path        : String;
      Stale_After : Duration;
      Max_Tries   : Positive;
      L           : in out Lock)
   with Pre => not Held (L);

   --  Removes the directory. Does nothing when the lock is not held.
   procedure Release (L : in out Lock);

private

   type Lock is limited new Ada.Finalization.Limited_Controlled with record
      Path : Ada.Strings.Unbounded.Unbounded_String;
      Own  : Boolean := False;
   end record;

   overriding
   procedure Finalize (L : in out Lock);

end Synapse.Adapters.Dir_Lock;
