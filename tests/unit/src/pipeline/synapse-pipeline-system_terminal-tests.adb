with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.OS_Lib;

with AUnit.Assertions;

with Synapse.Test_Scratch;

package body Synapse.Pipeline.System_Terminal.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  The tests run the programs a POSIX system has, or the ones Windows has.
   function On_Windows return Boolean is
     (GNAT.OS_Lib.Directory_Separator = '\');

   function Has_Posix return Boolean
   is (not On_Windows and then Ada.Directories.Exists ("/bin/sh"));

   --  Whether the programs the tests run are there.
   function Can_Run return Boolean is (Has_Posix or else On_Windows);

   --  The command interpreter of the system, run with a command.
   function Shell
     (Posix : String; Windows : String := "")
      return Session_Process.Process_Request
   is
      Result : Session_Process.Process_Request;
   begin
      if On_Windows then
         Result.Program := To_Unbounded_String ("cmd.exe");
         Result.Arguments.Append (To_Unbounded_String ("/c"));
         Result.Arguments.Append
           (To_Unbounded_String (if Windows = "" then Posix else Windows));
      else
         Result.Program := To_Unbounded_String ("sh");
         Result.Arguments.Append (To_Unbounded_String ("-c"));
         Result.Arguments.Append (To_Unbounded_String (Posix));
      end if;
      return Result;
   end Shell;

   --  The program's progress once it has ended, or what it was after about
   --  five seconds.
   function Ended
     (T : in out System_Terminal; Id : Terminal_Process.Handle)
      return Terminal_Process.Progress is
   begin
      for Tenth in 1 .. 50 loop
         if not T.Look (Id).Running then
            return T.Look (Id);
         end if;
         delay 0.1;
      end loop;
      return (Running => True);
   end Ended;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Read_File (Path : String) return String is
      File : Ada.Text_IO.File_Type;
      Line : String (1 .. 4096);
      Last : Natural;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      Ada.Text_IO.Get_Line (File, Line, Last);
      Ada.Text_IO.Close (File);
      return Line (1 .. Last);
   end Read_File;

   procedure A_Program_Is_Watched_Until_It_Ends (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Terminal : System_Terminal;
   begin
      if not Can_Run then
         return;
      end if;
      declare
         Made : constant Terminal_Process.Launch :=
           Terminal.Start (Shell ("exit 3"));
      begin
         Assert (Made.Started, "it is started");
         declare
            Done : constant Terminal_Process.Progress :=
              Ended (Terminal, Made.Id);
         begin
            Assert
              (not Done.Running and then Done.Exit_Code = 3,
               "it ends with its own exit code");
            Assert
              (not Terminal.Look (Made.Id).Running,
               "and a look after that says it ended");
         end;
      end;
   end A_Program_Is_Watched_Until_It_Ends;

   procedure A_Program_That_Runs_Is_Stopped (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Terminal : System_Terminal;
   begin
      if not Can_Run then
         return;
      end if;
      declare
         Made : constant Terminal_Process.Launch :=
           Terminal.Start (Shell ("sleep 30", "ping -n 60 127.0.0.1 >nul"));
      begin
         Assert (Made.Started, "it is started");
         Assert (Terminal.Look (Made.Id).Running, "and still running");
         Terminal.Stop (Made.Id);
         Assert
           (not Terminal.Look (Made.Id).Running,
            "asked to stop, it has ended when Stop returns");
      end;
   end A_Program_That_Runs_Is_Stopped;

   procedure The_Program_Is_Given_Its_Directory_And_Environment
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch  : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      Terminal : System_Terminal;
      Out_File : constant String :=
        Synapse.Test_Scratch.Path (Scratch, "out.txt");
      Request  : Session_Process.Process_Request :=
        Shell
          ("echo ""$PIPELINE_PROBE $(pwd)"" > " & Out_File,
           "echo %PIPELINE_PROBE% %CD%> " & Out_File);
   begin
      if not Can_Run then
         return;
      end if;
      Request.Environment.Append (To_Unbounded_String ("PIPELINE_PROBE=env"));
      Request.Directory :=
        To_Unbounded_String (Synapse.Test_Scratch.Path (Scratch));
      declare
         Made : constant Terminal_Process.Launch := Terminal.Start (Request);
      begin
         Assert (Made.Started, "it is started");
         Assert (not Ended (Terminal, Made.Id).Running, "and it ends");
         Assert
           (Ada.Strings.Fixed.Index (Read_File (Out_File), "env ") = 1
            and then Has
                       (Read_File (Out_File),
                        Ada.Directories.Simple_Name
                          (Synapse.Test_Scratch.Path (Scratch))),
            "the added variable and the directory: " & Read_File (Out_File));
      end;
      Synapse.Test_Scratch.Remove (Scratch);
   end The_Program_Is_Given_Its_Directory_And_Environment;

   procedure A_Command_Line_That_Is_Too_Long_Is_Not_Started
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Terminal : System_Terminal;
      Request  : Session_Process.Process_Request := Shell ("exit 0");
   begin
      if not On_Windows then
         return;
      end if;
      Request.Arguments.Append
        (To_Unbounded_String ([1 .. 40_000 => 'x']));
      declare
         Made : constant Terminal_Process.Launch := Terminal.Start (Request);
      begin
         Assert
           (not Made.Started
            and then Has (To_String (Made.Problem), "more than Windows takes"),
            "a prompt that cannot be an argument is refused, and says why");
      end;
   end A_Command_Line_That_Is_Too_Long_Is_Not_Started;

   procedure A_Program_That_Is_Not_There_Is_Not_Started
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Terminal : System_Terminal;
      Request  : Session_Process.Process_Request;
   begin
      if not Can_Run then
         return;
      end if;
      Request.Program := To_Unbounded_String ("no-such-program-for-sessions");
      declare
         Made : constant Terminal_Process.Launch := Terminal.Start (Request);
      begin
         Assert
           (not Made.Started
            and then Ada.Strings.Fixed.Index
                       (To_String (Made.Problem),
                        "no-such-program-for-sessions") > 0,
            "it says which program was not found");
      end;
   end A_Program_That_Is_Not_There_Is_Not_Started;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.System_Terminal");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Program_Is_Watched_Until_It_Ends'Access,
         "A program is watched until it ends");
      Register_Routine
        (T, A_Program_That_Runs_Is_Stopped'Access,
         "A program that runs is stopped");
      Register_Routine
        (T, The_Program_Is_Given_Its_Directory_And_Environment'Access,
         "The program is given its directory and environment");
      Register_Routine
        (T, A_Command_Line_That_Is_Too_Long_Is_Not_Started'Access,
         "A command line that is too long is not started");
      Register_Routine
        (T, A_Program_That_Is_Not_There_Is_Not_Started'Access,
         "A program that is not there is not started");
   end Register_Tests;

end Synapse.Pipeline.System_Terminal.Tests;
