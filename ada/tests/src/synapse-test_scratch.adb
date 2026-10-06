with Ada.Calendar;
with Ada.Directories;
with Ada.Strings.Fixed;

with Synapse.Adapters.System_Process;
with Synapse.Core.Text_Lists;
with Synapse.Ports.Process_Runner;

package body Synapse.Test_Scratch is

   use Ada.Strings.Unbounded;

   Counter : Natural := 0;

   function Number (N : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Left));

   function Make return Scratch is
      Stamp : constant Natural :=
        Natural (Ada.Calendar.Seconds (Ada.Calendar.Clock) * 1000.0);
   begin
      Counter := Counter + 1;
      return Result : Scratch do
         Result.Path :=
           To_Unbounded_String
             (Ada.Directories.Current_Directory & "/obj/scratch-"
              & Number (Stamp) & "-" & Number (Counter));
         Ada.Directories.Create_Path (To_String (Result.Path));
      end return;
   end Make;

   procedure Remove (S : Scratch) is
   begin
      Ada.Directories.Delete_Tree (To_String (S.Path));
   exception
      when others =>
         null;
   end Remove;

   function Path (S : Scratch; Name : String := "") return String
   is (if Name = "" then To_String (S.Path)
       else To_String (S.Path) & "/" & Name);

   function Trim (S : String) return String is
      Last : Natural := S'Last;
   begin
      while Last >= S'First
        and then S (Last) in Character'Val (10) | Character'Val (13) | ' '
      loop
         Last := Last - 1;
      end loop;
      return S (S'First .. Last);
   end Trim;

   function Run
     (Dir : String; Args : Core.Text_Lists.Vector)
      return Ports.Process_Runner.Result
   is
      R : Adapters.System_Process.System_Runner;
   begin
      return R.Run ("git", Args, (Cwd => To_Unbounded_String (Dir),
                                  others => <>));
   end Run;

   function Vector
     (A1, A2, A3, A4, A5, A6 : String) return Core.Text_Lists.Vector
   is
      Result : Core.Text_Lists.Vector;
      Items  : constant array (1 .. 6) of access constant String :=
        [A1'Unrestricted_Access, A2'Unrestricted_Access,
         A3'Unrestricted_Access, A4'Unrestricted_Access,
         A5'Unrestricted_Access, A6'Unrestricted_Access];
   begin
      for Item of Items loop
         if Item.all /= "" then
            Result.Append (To_Unbounded_String (Item.all));
         end if;
      end loop;
      return Result;
   end Vector;

   function Git (Dir : String; A1 : String; A2, A3, A4, A5, A6 : String := "")
      return String
   is
      Result : constant Ports.Process_Runner.Result :=
        Run (Dir, Vector (A1, A2, A3, A4, A5, A6));
   begin
      if Result.Exit_Code /= 0 then
         raise Program_Error
           with "git " & A1 & " failed: " & To_String (Result.Errors);
      end if;
      return Trim (To_String (Result.Output));
   end Git;

   procedure Git (Dir : String; A1 : String; A2, A3, A4, A5, A6 : String := "")
   is
      Ignore : constant Ports.Process_Runner.Result :=
        Run (Dir, Vector (A1, A2, A3, A4, A5, A6));
   begin
      null;
   end Git;

   function Commit_Count (Dir : String) return Natural is
      Result : constant Ports.Process_Runner.Result :=
        Run (Dir, Vector ("rev-list", "--count", "HEAD", "", "", ""));
   begin
      if Result.Exit_Code /= 0 then
         return 0;
      end if;
      return Natural'Value (Trim (To_String (Result.Output)));
   end Commit_Count;

   function Head_Subject (Dir : String) return String
   is (Git (Dir, "log", "-1", "--format=%s"));

   procedure Init_Repo (Dir : String) is
   begin
      Ada.Directories.Create_Path (Dir);
      Git (Dir, "init", "-q", "-b", "main");
      Git (Dir, "config", "user.email", "test@example.com");
      Git (Dir, "config", "user.name", "Test");
   end Init_Repo;

end Synapse.Test_Scratch;
