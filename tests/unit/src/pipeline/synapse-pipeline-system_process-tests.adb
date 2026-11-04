with Ada.Calendar;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with GNAT.OS_Lib;

with Synapse.Test_Scratch;

package body Synapse.Pipeline.System_Process.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  The first tests run programs a POSIX system has; the ones for Windows
   --  run programs it has.
   function Has_Posix return Boolean
   is (Ada.Directories.Exists ("/bin/sh"));

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   --  A shell command as a request.
   function Shell
     (Command : String; Seconds : Positive := 30)
      return Session_Process.Process_Request
   is
      Result : Session_Process.Process_Request;
   begin
      Result.Program := To_Unbounded_String ("sh");
      Result.Arguments.Append (To_Unbounded_String ("-c"));
      Result.Arguments.Append (To_Unbounded_String (Command));
      Result.Timeout_Seconds := Seconds;
      return Result;
   end Shell;

   procedure What_The_Program_Wrote_Is_Returned
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P   : System_Process;
      Got : constant Session_Process.Process_Outcome :=
        P.Run (Shell ("echo out; echo err >&2; exit 3"));
   begin
      if not Has_Posix then
         return;
      end if;
      Assert
        (Got.Started and then not Got.Timed_Out,
         "it ran to its end: started=" & Got.Started'Image & " timed_out="
         & Got.Timed_Out'Image & " problem=" & To_String (Got.Problem));
      Assert
        (Got.Exit_Code = 3
         and then To_String (Got.Output) = "out" & LF
         and then To_String (Got.Errors) = "err" & LF,
         "its exit code and both streams: "
         & Integer'Image (Got.Exit_Code) & To_String (Got.Output));
   end What_The_Program_Wrote_Is_Returned;

   procedure The_Program_Is_Given_Its_Input_Directory_And_Environment
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      P       : System_Process;
      Request : Session_Process.Process_Request :=
        Shell ("read line; echo ""$line $PIPELINE_PROBE""; pwd");
   begin
      if not Has_Posix then
         return;
      end if;
      Request.Standard_Input := To_Unbounded_String ("from stdin" & LF);
      Request.Environment.Append (To_Unbounded_String ("PIPELINE_PROBE=env"));
      Request.Directory :=
        To_Unbounded_String (Synapse.Test_Scratch.Path (Scratch));
      declare
         Got : constant Session_Process.Process_Outcome := P.Run (Request);
      begin
         Assert
           (Has (To_String (Got.Output), "from stdin env" & LF),
            "stdin and the added variable: " & To_String (Got.Output));
         Assert
           (Has
              (To_String (Got.Output),
               Ada.Strings.Fixed.Trim
                 (Synapse.Test_Scratch.Path (Scratch),
                  Ada.Strings.Right)),
            "the directory: " & To_String (Got.Output));
      end;
      Synapse.Test_Scratch.Remove (Scratch);
   end The_Program_Is_Given_Its_Input_Directory_And_Environment;

   procedure A_Program_That_Is_Not_There_Is_Not_Started
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P       : System_Process;
      Request : Session_Process.Process_Request;
   begin
      if not Has_Posix then
         return;
      end if;
      Request.Program := To_Unbounded_String ("no-such-harness-program");
      declare
         Got : constant Session_Process.Process_Outcome := P.Run (Request);
      begin
         Assert
           (not Got.Started
            and then Has (To_String (Got.Problem), "no-such-harness-program"),
            "it says which: " & To_String (Got.Problem));
      end;
   end A_Program_That_Is_Not_There_Is_Not_Started;

   procedure A_Program_Past_Its_Limit_Is_Stopped_With_What_It_Started
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P       : System_Process;
      Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Got     : constant Session_Process.Process_Outcome :=
        P.Run (Shell ("sleep 60 & wait", Seconds => 1));
      Taken   : constant Duration :=
        Ada.Calendar."-" (Ada.Calendar.Clock, Started);
   begin
      if not Has_Posix then
         return;
      end if;
      Assert (Got.Started and then Got.Timed_Out, "it timed out");
      Assert (Taken < 20.0, "and was stopped, not waited for:" & Taken'Image);
   end A_Program_Past_Its_Limit_Is_Stopped_With_What_It_Started;

   procedure A_Program_Within_Its_Limit_Is_Not_Marked_Timed_Out
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P   : System_Process;
      Got : constant Session_Process.Process_Outcome :=
        P.Run (Shell ("exit 0", Seconds => 30));
   begin
      if not Has_Posix then
         return;
      end if;
      Assert
        (Got.Started and then not Got.Timed_Out and then Got.Exit_Code = 0,
         "it finished in time");
   end A_Program_Within_Its_Limit_Is_Not_Marked_Timed_Out;

   ---------------------------------------------------------------------------
   --  Windows
   ---------------------------------------------------------------------------

   CR : constant Character := Character'Val (13);

   function On_Windows return Boolean is
     (GNAT.OS_Lib.Directory_Separator = '\');

   --  A program with its arguments as a request.
   function Program
     (Name : String; A1, A2, A3 : String := ""; Seconds : Positive := 30)
      return Session_Process.Process_Request
   is
      Result : Session_Process.Process_Request;

      procedure Add (Arg : String) is
      begin
         if Arg /= "" then
            Result.Arguments.Append (To_Unbounded_String (Arg));
         end if;
      end Add;
   begin
      Result.Program := To_Unbounded_String (Name);
      Add (A1);
      Add (A2);
      Add (A3);
      Result.Timeout_Seconds := Seconds;
      return Result;
   end Program;

   procedure On_Windows_What_The_Program_Wrote_Is_Returned
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : System_Process;
   begin
      if not On_Windows then
         return;
      end if;
      declare
         Got : constant Session_Process.Process_Outcome :=
           P.Run
             (Program
                ("cmd.exe", "/c", "echo out& echo err>&2& exit /b 3"));
      begin
         Assert
           (Got.Started and then not Got.Timed_Out,
            "it ran to its end: " & To_String (Got.Problem));
         Assert (Got.Exit_Code = 3, "its exit code:" & Got.Exit_Code'Image);
         Assert
           (Has (To_String (Got.Output), "out")
            and then not Has (To_String (Got.Output), "err"),
            "what it wrote to its output: " & To_String (Got.Output));
         Assert
           (Has (To_String (Got.Errors), "err")
            and then not Has (To_String (Got.Errors), "out"),
            "and to its errors: " & To_String (Got.Errors));
      end;
   end On_Windows_What_The_Program_Wrote_Is_Returned;

   procedure On_Windows_The_Program_Is_Given_Its_Input_And_Surroundings
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      P : System_Process;
   begin
      if not On_Windows then
         return;
      end if;
      declare
         Asked : Session_Process.Process_Request :=
           Program ("findstr", "^");
      begin
         Asked.Standard_Input := To_Unbounded_String ("from stdin" & LF);
         declare
            Got : constant Session_Process.Process_Outcome := P.Run (Asked);
         begin
            Assert
              (Got.Started and then Has (To_String (Got.Output), "from stdin"),
               "its input reaches it: " & To_String (Got.Output)
               & To_String (Got.Problem));
         end;
      end;
      declare
         Asked : Session_Process.Process_Request :=
           Program ("cmd.exe", "/c", "echo %PIPELINE_PROBE%& cd");
      begin
         Asked.Environment.Append
           (To_Unbounded_String ("PIPELINE_PROBE=env"));
         Asked.Directory :=
           To_Unbounded_String (Synapse.Test_Scratch.Path (Scratch));
         declare
            Got : constant Session_Process.Process_Outcome := P.Run (Asked);
         begin
            Assert
              (Has (To_String (Got.Output), "env"),
               "the variable it was given: " & To_String (Got.Output));
            Assert
              (Has
                 (To_String (Got.Output),
                  Ada.Directories.Simple_Name
                    (Synapse.Test_Scratch.Path (Scratch))),
               "and the directory: " & To_String (Got.Output));
         end;
      end;
   end On_Windows_The_Program_Is_Given_Its_Input_And_Surroundings;

   procedure On_Windows_A_Program_That_Is_Not_There_Is_Not_Started
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : System_Process;
   begin
      if not On_Windows then
         return;
      end if;
      declare
         Got : constant Session_Process.Process_Outcome :=
           P.Run (Program ("no-such-harness-program"));
      begin
         Assert
           (not Got.Started
            and then Has (To_String (Got.Problem), "no-such-harness-program"),
            "it says which: " & To_String (Got.Problem));
      end;
   end On_Windows_A_Program_That_Is_Not_There_Is_Not_Started;

   procedure On_Windows_A_Program_Past_Its_Limit_Is_Stopped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : System_Process;
   begin
      if not On_Windows then
         return;
      end if;
      declare
         Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
         Got     : constant Session_Process.Process_Outcome :=
           P.Run (Program ("ping", "-n", "60", "127.0.0.1", Seconds => 1));
         Taken   : constant Duration :=
           Ada.Calendar."-" (Ada.Calendar.Clock, Started);
      begin
         Assert
           (Got.Started and then Got.Timed_Out,
            "it timed out: " & To_String (Got.Problem));
         Assert
           (Taken < 30.0, "and was stopped, not waited for:" & Taken'Image);
      end;
      declare
         Got : constant Session_Process.Process_Outcome :=
           P.Run (Program ("cmd.exe", "/c", "exit 0", Seconds => 30));
      begin
         Assert
           (Got.Started and then not Got.Timed_Out and then Got.Exit_Code = 0,
            "a program within its limit is not marked timed out");
      end;
   end On_Windows_A_Program_Past_Its_Limit_Is_Stopped;

   procedure On_Windows_A_Command_Script_Is_Run
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      Script  : constant String :=
        Synapse.Test_Scratch.Path (Scratch) & "\show-argument.cmd";
      File    : Ada.Streams.Stream_IO.File_Type;
      P       : System_Process;
   begin
      if not On_Windows then
         return;
      end if;
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Script);
      String'Write
        (Ada.Streams.Stream_IO.Stream (File),
         "@echo off" & CR & LF & "echo got %1" & CR & LF);
      Ada.Streams.Stream_IO.Close (File);
      declare
         Got : constant Session_Process.Process_Outcome :=
           P.Run (Program (Script, "a b"));
      begin
         Assert
           (Got.Started and then Has (To_String (Got.Output), "got ""a b"""),
            "a script gets its argument as one: " & To_String (Got.Output)
            & To_String (Got.Problem));
      end;
   end On_Windows_A_Command_Script_Is_Run;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.System_Process");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, What_The_Program_Wrote_Is_Returned'Access,
         "What the program wrote is returned");
      Register_Routine
        (T, The_Program_Is_Given_Its_Input_Directory_And_Environment'Access,
         "The program is given its input, directory and environment");
      Register_Routine
        (T, A_Program_That_Is_Not_There_Is_Not_Started'Access,
         "A program that is not there is not started");
      Register_Routine
        (T, A_Program_Past_Its_Limit_Is_Stopped_With_What_It_Started'Access,
         "A program past its limit is stopped with what it started");
      Register_Routine
        (T, A_Program_Within_Its_Limit_Is_Not_Marked_Timed_Out'Access,
         "A program within its limit is not marked timed out");
      Register_Routine
        (T, On_Windows_What_The_Program_Wrote_Is_Returned'Access,
         "On Windows what the program wrote is returned");
      Register_Routine
        (T, On_Windows_The_Program_Is_Given_Its_Input_And_Surroundings'Access,
         "On Windows the program is given its input, directory and "
         & "environment");
      Register_Routine
        (T, On_Windows_A_Program_That_Is_Not_There_Is_Not_Started'Access,
         "On Windows a program that is not there is not started");
      Register_Routine
        (T, On_Windows_A_Program_Past_Its_Limit_Is_Stopped'Access,
         "On Windows a program past its limit is stopped");
      Register_Routine
        (T, On_Windows_A_Command_Script_Is_Run'Access,
         "On Windows a command script is run");
   end Register_Tests;

end Synapse.Pipeline.System_Process.Tests;
