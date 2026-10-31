with Ada.Calendar;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Test_Scratch;

package body Synapse.Pipeline.System_Process.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  These tests run programs a POSIX system has; Windows has its own
   --  adapter, which says it cannot run a program.
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

   procedure Without_A_Posix_System_No_Program_Is_Started
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P   : System_Process;
      Got : Session_Process.Process_Outcome;
   begin
      if Has_Posix then
         return;
      end if;
      Got := P.Run (Shell ("exit 0"));
      Assert
        (not Got.Started
         and then Has (To_String (Got.Problem), "not available"),
         "it says so: " & To_String (Got.Problem));
   end Without_A_Posix_System_No_Program_Is_Started;

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
        (T, Without_A_Posix_System_No_Program_Is_Started'Access,
         "Without a POSIX system no program is started");
   end Register_Tests;

end Synapse.Pipeline.System_Process.Tests;
