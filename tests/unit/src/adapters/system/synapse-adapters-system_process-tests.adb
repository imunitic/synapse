with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;

package body Synapse.Adapters.System_Process.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  These tests use programs a POSIX system has; Windows has its own.
   function Has_Posix return Boolean
   is (Ada.Directories.Exists ("/bin/sh"));

   function Args (A, B, C, D : String := "") return Core.Text_Lists.Vector is
      Result : Core.Text_Lists.Vector;
   begin
      if A /= "" then
         Result.Append (To_Unbounded_String (A));
      end if;
      if B /= "" then
         Result.Append (To_Unbounded_String (B));
      end if;
      if C /= "" then
         Result.Append (To_Unbounded_String (C));
      end if;
      if D /= "" then
         Result.Append (To_Unbounded_String (D));
      end if;
      return Result;
   end Args;

   function Shell
     (Script : String;
      Rest   : Core.Text_Lists.Vector := Core.Text_Lists.Vectors.Empty_Vector;
      Opts   : Port.Options := (others => <>)) return Port.Result
   is
      R    : System_Runner;
      List : Core.Text_Lists.Vector;
   begin
      List.Append (To_Unbounded_String ("-c"));
      List.Append (To_Unbounded_String (Script));
      List.Append (To_Unbounded_String ("sh"));
      for A of Rest loop
         List.Append (A);
      end loop;
      return R.Run ("/bin/sh", List, Opts);
   end Shell;

   procedure Output_And_A_Zero_Exit_Are_Captured (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R   : System_Runner;
      Got : Port.Result;
   begin
      if not Has_Posix then
         return;
      end if;
      Got := R.Run ("/bin/echo", Args ("hello"), (others => <>));
      Assert (To_String (Got.Output) = "hello" & LF, "stdout");
      Assert (To_String (Got.Errors) = "", "stderr is empty");
      Assert (Got.Exit_Code = 0 and then Port.Succeeded (Got), "success");
   end Output_And_A_Zero_Exit_Are_Captured;

   procedure A_Non_Zero_Exit_Is_A_Result (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Got : Port.Result;
   begin
      if not Has_Posix then
         return;
      end if;
      Got := Shell ("exit 3");
      Assert (Got.Exit_Code = 3, "the code:" & Got.Exit_Code'Image);
      Assert (not Port.Succeeded (Got), "not a success");
   end A_Non_Zero_Exit_Is_A_Result;

   procedure Output_And_Errors_Are_Kept_Apart (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Got : Port.Result;
   begin
      if not Has_Posix then
         return;
      end if;
      Got := Shell ("echo out; echo err >&2");
      Assert (To_String (Got.Output) = "out" & LF, "stdout");
      Assert (To_String (Got.Errors) = "err" & LF, "stderr");
   end Output_And_Errors_Are_Kept_Apart;

   procedure Input_Is_Fed_And_Closed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R    : System_Runner;
      Got  : Port.Result;
      Big  : constant String (1 .. 512 * 1024) := [others => 'x'];
   begin
      if not Has_Posix then
         return;
      end if;
      Got := R.Run ("/bin/cat", Args ("-"),
                    (Has_Stdin => True,
                     Stdin     => To_Unbounded_String ("piped" & LF),
                     others    => <>));
      Assert (To_String (Got.Output) = "piped" & LF, "stdin to stdout");
      Assert (Port.Succeeded (Got), "and it ended");

      --  Both directions far beyond a pipe buffer.
      Got := R.Run ("/bin/cat", Args ("-"),
                    (Has_Stdin => True,
                     Stdin     => To_Unbounded_String (Big),
                     others    => <>));
      Assert (Length (Got.Output) = Big'Length, "all of it came back");

      Got := R.Run ("/bin/cat", Args ("-"),
                    (Has_Stdin => True, others => <>));
      Assert (Length (Got.Output) = 0 and then Port.Succeeded (Got),
              "empty input");
   end Input_Is_Fed_And_Closed;

   procedure Nothing_Is_Fed_Without_Input (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R   : System_Runner;
      Got : Port.Result;
   begin
      if not Has_Posix then
         return;
      end if;
      Got := R.Run ("/bin/cat", Args ("-"), (others => <>));
      Assert (Length (Got.Output) = 0 and then Port.Succeeded (Got),
              "standard input is empty, not the terminal");
   end Nothing_Is_Fed_Without_Input;

   procedure The_Working_Directory_Is_Honoured (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Base : constant String :=
        Ada.Directories.Current_Directory & "/obj/process-test-cwd";
      Got  : Port.Result;
   begin
      if not Has_Posix then
         return;
      end if;
      Ada.Directories.Create_Path (Base & "/inner dir");
      Got := Shell ("pwd", Opts => (Cwd => To_Unbounded_String
                                           (Base & "/inner dir"),
                                    others => <>));
      Assert (Ada.Strings.Fixed.Index (To_String (Got.Output),
                                       "/process-test-cwd/inner dir") > 0,
              "ran there: " & To_String (Got.Output) & "|"
              & To_String (Got.Errors) & "|" & Got.Exit_Code'Image);
      Got := Shell ("true", Opts => (Cwd => To_Unbounded_String
                                              (Base & "/missing"),
                                     others => <>));
      Assert (Got.Exit_Code = 127, "a missing directory fails the run");
      Ada.Directories.Delete_Tree (Base);
   exception
      when others =>
         if Ada.Directories.Exists (Base) then
            Ada.Directories.Delete_Tree (Base);
         end if;
         raise;
   end The_Working_Directory_Is_Honoured;

   procedure Arguments_Arrive_Unchanged (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Got : Port.Result;
      List : Core.Text_Lists.Vector;
   begin
      if not Has_Posix then
         return;
      end if;
      List.Append (To_Unbounded_String ("with space"));
      List.Append (To_Unbounded_String ("it's"));
      List.Append (To_Unbounded_String ("say ""hi"""));
      List.Append (To_Unbounded_String ("$HOME `date` $(id)"));
      List.Append (To_Unbounded_String ("back\slash\n"));
      List.Append (To_Unbounded_String ("*?[a-z]"));
      List.Append (To_Unbounded_String (""));
      List.Append (To_Unbounded_String ("line" & LF & "break"));
      List.Append (To_Unbounded_String ("-n"));
      List.Append (To_Unbounded_String ("; echo injected"));
      Got := Shell ("for a in ""$@""; do printf '<%s>' ""$a""; done", List);
      Assert (To_String (Got.Output)
              = "<with space><it's><say ""hi""><$HOME `date` $(id)>"
                & "<back\slash\n><*?[a-z]><><line" & LF & "break><-n>"
                & "<; echo injected>", "every argument as written: "
                & To_String (Got.Output));
   end Arguments_Arrive_Unchanged;

   procedure A_Missing_Program_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R      : System_Runner;
      Raised : Boolean := False;
   begin
      begin
         declare
            Ignore : constant Port.Result :=
              R.Run ("synapse-no-such-program-anywhere", Args, (others => <>));
         begin
            null;
         end;
      exception
         when Port.Process_Failure =>
            Raised := True;
      end;
      Assert (Raised, "Process_Failure");
   end A_Missing_Program_Raises;

   procedure A_Program_Is_Found_On_The_Path (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R    : System_Runner;
      Dir  : constant String :=
        Ada.Directories.Current_Directory & "/obj/process-test-path";
      Old  : constant String :=
        (if Ada.Environment_Variables.Exists ("PATH")
         then Ada.Environment_Variables.Value ("PATH") else "");
      Got  : Port.Result;
   begin
      if not Has_Posix then
         return;
      end if;
      Ada.Directories.Create_Path (Dir);
      File_Bytes.Write (Dir & "/synapse-path-probe",
                        "#!/bin/sh" & LF & "echo found via PATH" & LF);
      Shell_Chmod : declare
         Ignore : constant Port.Result :=
           Shell ("chmod +x ""$1""",
                  Args (Dir & "/synapse-path-probe"));
      begin
         null;
      end Shell_Chmod;
      Ada.Environment_Variables.Set ("PATH", Dir & ":" & Old);
      Got := R.Run ("synapse-path-probe", Args, (others => <>));
      Ada.Environment_Variables.Set ("PATH", Old);
      Assert (To_String (Got.Output) = "found via PATH" & LF, "by bare name");
      Ada.Directories.Delete_Tree (Dir);
   exception
      when others =>
         Ada.Environment_Variables.Set ("PATH", Old);
         if Ada.Directories.Exists (Dir) then
            Ada.Directories.Delete_Tree (Dir);
         end if;
         raise;
   end A_Program_Is_Found_On_The_Path;

   procedure A_Killed_Program_Reports_A_Failure (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : Port.Result;
   begin
      if not Has_Posix then
         return;
      end if;
      Got := Shell ("kill -9 $$");
      Assert (Got.Exit_Code /= 0, "not a success: " & Got.Exit_Code'Image);
   end A_Killed_Program_Reports_A_Failure;

   --  The temporary files a run leaves in the temporary directory.
   function Temp_Files return Natural is
      use Ada.Directories;
      Search : Search_Type;
      Item   : Directory_Entry_Type;
      Count  : Natural := 0;
   begin
      Start_Search (Search, File_Bytes.Temp_Dir, "synapse-*.tmp");
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         Count := Count + 1;
      end loop;
      End_Search (Search);
      return Count;
   end Temp_Files;

   procedure No_Temporary_File_Is_Left_Behind (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R      : System_Runner;
      Before : constant Natural := Temp_Files;
      Raised : Boolean := False;
   begin
      if not Has_Posix then
         return;
      end if;
      Assert (R.Run ("/bin/cat", Args ("-"),
                     (Has_Stdin => True,
                      Stdin => To_Unbounded_String ("x"), others => <>))
                .Exit_Code = 0, "a run with input");
      Assert (Shell ("exit 2").Exit_Code = 2, "a failing run");
      begin
         Assert (R.Run ("synapse-no-such-program-anywhere", Args,
                        (others => <>)).Exit_Code /= 0, "unreachable");
      exception
         when Port.Process_Failure =>
            Raised := True;
      end;
      Assert (Raised, "the failed start raised");
      Assert (Temp_Files = Before, "the same temporary files as before");
   end No_Temporary_File_Is_Left_Behind;

   procedure Too_Much_Output_Is_A_Failure (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      if not Has_Posix then
         return;
      end if;
      begin
         declare
            Ignore : constant Port.Result :=
              Shell ("dd if=/dev/zero bs=1048576 count=65 2>/dev/null");
         begin
            null;
         end;
      exception
         when Port.Process_Failure =>
            Raised := True;
      end;
      Assert (Raised, "over 64 MiB raises");
   end Too_Much_Output_Is_A_Failure;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.System_Process");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Output_And_A_Zero_Exit_Are_Captured'Access,
         "Output and a zero exit are captured");
      Register_Routine
        (T, A_Non_Zero_Exit_Is_A_Result'Access,
         "A non-zero exit is a result");
      Register_Routine
        (T, Output_And_Errors_Are_Kept_Apart'Access,
         "Output and errors are kept apart");
      Register_Routine
        (T, Input_Is_Fed_And_Closed'Access, "Input is fed and closed");
      Register_Routine
        (T, Nothing_Is_Fed_Without_Input'Access,
         "Nothing is fed without input");
      Register_Routine
        (T, The_Working_Directory_Is_Honoured'Access,
         "The working directory is honoured");
      Register_Routine
        (T, Arguments_Arrive_Unchanged'Access, "Arguments arrive unchanged");
      Register_Routine
        (T, A_Missing_Program_Raises'Access, "A missing program raises");
      Register_Routine
        (T, A_Program_Is_Found_On_The_Path'Access,
         "A program is found on the path");
      Register_Routine
        (T, A_Killed_Program_Reports_A_Failure'Access,
         "A killed program reports a failure");
      Register_Routine
        (T, No_Temporary_File_Is_Left_Behind'Access,
         "No temporary file is left behind");
      Register_Routine
        (T, Too_Much_Output_Is_A_Failure'Access,
         "Too much output is a failure");
   end Register_Tests;

end Synapse.Adapters.System_Process.Tests;
