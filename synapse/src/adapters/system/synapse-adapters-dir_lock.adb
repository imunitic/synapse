with Ada.Calendar;
with Ada.Directories;

package body Synapse.Adapters.Dir_Lock is

   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;

   function Held (L : Lock) return Boolean
   is (L.Own);

   --  Whether Path is older than the window. Unreadable is not abandoned: a
   --  lock that vanished while being looked at is not ours to reason about.
   function Abandoned (Path : String; Stale_After : Duration) return Boolean is
   begin
      return
        Ada.Calendar.Clock - Ada.Directories.Modification_Time (Path)
        > Stale_After;
   exception
      when others =>
         return False;
   end Abandoned;

   function Create (Path : String) return Boolean is
   begin
      Ada.Directories.Create_Directory (Path);
      return True;
   exception
      when others =>
         return False;
   end Create;

   procedure Try_Acquire
     (Path : String; Stale_After : Duration; L : in out Lock) is
   begin
      if Create (Path) then
         L.Path := To_Unbounded_String (Path);
         L.Own := True;
         return;
      end if;
      if Abandoned (Path, Stale_After) then
         begin
            Ada.Directories.Delete_Directory (Path);
         exception
            when others =>
               null;
         end;
         if Create (Path) then
            L.Path := To_Unbounded_String (Path);
            L.Own := True;
         end if;
      end if;
   end Try_Acquire;

   procedure Acquire_With_Retry
     (Path        : String;
      Stale_After : Duration;
      Max_Tries   : Positive;
      L           : in out Lock) is
   begin
      for Attempt in 1 .. Max_Tries loop
         Try_Acquire (Path, Stale_After, L);
         exit when L.Own;
         if Attempt < Max_Tries then
            delay 0.2;
         end if;
      end loop;
   end Acquire_With_Retry;

   procedure Release (L : in out Lock) is
   begin
      if L.Own then
         L.Own := False;
         begin
            Ada.Directories.Delete_Directory (To_String (L.Path));
         exception
            when others =>
               null;
         end;
      end if;
   end Release;

   overriding
   procedure Finalize (L : in out Lock) is
   begin
      Release (L);
   end Finalize;

end Synapse.Adapters.Dir_Lock;
