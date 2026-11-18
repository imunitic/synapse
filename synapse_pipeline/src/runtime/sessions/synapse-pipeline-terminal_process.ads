with Ada.Strings.Unbounded;

with Synapse.Pipeline.Session_Process;

--  Running one program for a session on the terminal the caller was given: it
--  reads the caller's input and writes to the caller's output, so a person
--  can use it, and it is watched while it runs and stopped when the caller is
--  done with it. Implementations are System_Terminal and, for tests,
--  Fake_Terminal.

package Synapse.Pipeline.Terminal_Process is

   --  What the system calls a program that was started.
   type Handle is new Long_Integer;

   type Launch (Started : Boolean := False) is record
      case Started is
         when True  => Id      : Handle;
         when False => Problem : Ada.Strings.Unbounded.Unbounded_String;
      end case;
   end record;

   type Progress (Running : Boolean := True) is record
      case Running is
         when True  => null;
         when False => Exit_Code : Integer;
      end case;
   end record;

   type Terminal is limited interface;

   --  Starts the program of Request with its arguments, in its directory and
   --  with its environment, on the caller's terminal, and does not wait for
   --  it. Its standard input and its time limit are not used: the program
   --  reads the terminal, and the caller decides how long it runs. Never
   --  raises.
   function Start
     (T       : in out Terminal;
      Request : Session_Process.Process_Request) return Launch
   is abstract;

   --  Whether the program is still running, and how it ended when it is not.
   --  Asked once a program has ended, it says the same.
   function Look
     (T : in out Terminal; Id : Handle) return Progress is abstract;

   --  Asks the program to stop and, if it has not after a grace period, makes
   --  it. Returns when it has ended.
   procedure Stop (T : in out Terminal; Id : Handle) is abstract;

end Synapse.Pipeline.Terminal_Process;
