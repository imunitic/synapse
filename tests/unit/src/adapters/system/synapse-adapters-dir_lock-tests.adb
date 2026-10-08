with Ada.Directories;

with AUnit.Assertions;

package body Synapse.Adapters.Dir_Lock.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   Base : constant String := "obj/dir-lock-tests";

   function Path (Name : String) return String
   is (Ada.Directories.Current_Directory & "/" & Base & "/" & Name);

   procedure Fresh is
   begin
      if Ada.Directories.Exists (Base) then
         Ada.Directories.Delete_Tree (Base);
      end if;
      Ada.Directories.Create_Path (Base);
   end Fresh;

   procedure Creating_The_Directory_Takes_The_Lock
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      L : Lock;
   begin
      Fresh;
      Try_Acquire (Path ("x.lock"), 60.0, L);
      Assert (Held (L), "held");
      Assert (Ada.Directories.Exists (Path ("x.lock")),
              "the directory exists");
   end Creating_The_Directory_Takes_The_Lock;

   procedure A_Fresh_Lock_Cannot_Be_Taken_Twice
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      First, Second : Lock;
   begin
      Fresh;
      Try_Acquire (Path ("x.lock"), 60.0, First);
      Try_Acquire (Path ("x.lock"), 60.0, Second);
      Assert (Held (First), "the first holds it");
      Assert (not Held (Second), "the second does not");
      Assert (Ada.Directories.Exists (Path ("x.lock")),
              "and the failed attempt did not remove it");
   end A_Fresh_Lock_Cannot_Be_Taken_Twice;

   procedure Release_Frees_The_Lock (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      First, Second : Lock;
   begin
      Fresh;
      Try_Acquire (Path ("x.lock"), 60.0, First);
      Release (First);
      Assert (not Held (First), "no longer held");
      Assert (not Ada.Directories.Exists (Path ("x.lock")), "directory gone");
      Release (First);  --  twice is harmless
      Try_Acquire (Path ("x.lock"), 60.0, Second);
      Assert (Held (Second), "a later acquire succeeds");
   end Release_Frees_The_Lock;

   procedure An_Abandoned_Lock_Is_Stolen (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Mine : Lock;
   begin
      Fresh;
      Ada.Directories.Create_Directory (Path ("x.lock"));
      delay 0.3;
      Try_Acquire (Path ("x.lock"), 0.1, Mine);
      Assert (Held (Mine), "older than the window, so taken");
   end An_Abandoned_Lock_Is_Stolen;

   procedure A_Lock_Within_The_Window_Is_Respected
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Mine : Lock;
   begin
      Fresh;
      Ada.Directories.Create_Directory (Path ("x.lock"));
      Try_Acquire (Path ("x.lock"), 3600.0, Mine);
      Assert (not Held (Mine), "someone else holds it");
      Assert (Ada.Directories.Exists (Path ("x.lock")),
              "and it is still there");
   end A_Lock_Within_The_Window_Is_Respected;

   procedure A_Lock_Is_Released_When_Its_Scope_Is_Left
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Fresh;
      begin
         declare
            L : Lock;
         begin
            Try_Acquire (Path ("x.lock"), 60.0, L);
            raise Constraint_Error;
         end;
      exception
         when Constraint_Error =>
            null;
      end;
      Assert (not Ada.Directories.Exists (Path ("x.lock")),
              "an exception left no lock behind");
      declare
         L : Lock;
      begin
         Try_Acquire (Path ("x.lock"), 60.0, L);
         Assert (Held (L), "free again");
      end;
      Assert (not Ada.Directories.Exists (Path ("x.lock")), "and released");
   end A_Lock_Is_Released_When_Its_Scope_Is_Left;

   procedure A_Lock_That_Could_Not_Be_Taken_Is_Not_Released
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Fresh;
      Ada.Directories.Create_Directory (Path ("x.lock"));
      declare
         L : Lock;
      begin
         Try_Acquire (Path ("x.lock"), 3600.0, L);
      end;
      Assert (Ada.Directories.Exists (Path ("x.lock")),
              "another holder's lock survives our scope");
   end A_Lock_That_Could_Not_Be_Taken_Is_Not_Released;

   procedure A_Missing_Parent_Cannot_Be_Locked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      L : Lock;
   begin
      Fresh;
      Try_Acquire (Path ("no/such/parent/x.lock"), 60.0, L);
      Assert (not Held (L), "nothing to create it in");
   end A_Missing_Parent_Cannot_Be_Locked;

   --  The holder lets go partway through the retries.
   task type Releaser (Lock_Path : access constant String) is
      entry Start;
   end Releaser;

   task body Releaser is
   begin
      accept Start;
      delay 0.15;
      Ada.Directories.Delete_Directory (Lock_Path.all);
   end Releaser;

   procedure Retry_Waits_Out_A_Short_Lived_Holder (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Where : aliased constant String := Path ("x.lock");
      Mine  : Lock;
   begin
      Fresh;
      Ada.Directories.Create_Directory (Where);
      declare
         Holder : Releaser (Where'Access);
      begin
         Holder.Start;
         Acquire_With_Retry (Where, 3600.0, 10, Mine);
      end;
      Assert (Held (Mine), "taken once the holder let go");
   end Retry_Waits_Out_A_Short_Lived_Holder;

   procedure Retry_Gives_Up_After_Its_Tries (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Mine : Lock;
   begin
      Fresh;
      Ada.Directories.Create_Directory (Path ("x.lock"));
      Acquire_With_Retry (Path ("x.lock"), 3600.0, 2, Mine);
      Assert (not Held (Mine), "never released, so never taken");
   end Retry_Gives_Up_After_Its_Tries;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Dir_Lock");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Creating_The_Directory_Takes_The_Lock'Access,
         "Creating the directory takes the lock");
      Register_Routine
        (T, A_Fresh_Lock_Cannot_Be_Taken_Twice'Access,
         "A fresh lock cannot be taken twice");
      Register_Routine
        (T, Release_Frees_The_Lock'Access, "Release frees the lock");
      Register_Routine
        (T, An_Abandoned_Lock_Is_Stolen'Access,
         "An abandoned lock is stolen");
      Register_Routine
        (T, A_Lock_Within_The_Window_Is_Respected'Access,
         "A lock within the window is respected");
      Register_Routine
        (T, A_Lock_Is_Released_When_Its_Scope_Is_Left'Access,
         "A lock is released when its scope is left");
      Register_Routine
        (T, A_Lock_That_Could_Not_Be_Taken_Is_Not_Released'Access,
         "A lock that could not be taken is not released");
      Register_Routine
        (T, A_Missing_Parent_Cannot_Be_Locked'Access,
         "A missing parent cannot be locked");
      Register_Routine
        (T, Retry_Waits_Out_A_Short_Lived_Holder'Access,
         "Retry waits out a short-lived holder");
      Register_Routine
        (T, Retry_Gives_Up_After_Its_Tries'Access,
         "Retry gives up after its tries");
   end Register_Tests;

end Synapse.Adapters.Dir_Lock.Tests;
