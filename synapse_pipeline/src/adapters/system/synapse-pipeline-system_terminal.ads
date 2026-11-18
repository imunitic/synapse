with Ada.Containers.Ordered_Maps;

with System;

with Synapse.Pipeline.Session_Process;
with Synapse.Pipeline.Terminal_Process;

--  Runs programs on the terminal of this program, through the operating
--  system. The body is chosen per platform. A program started this way stays
--  in this program's process group, which a terminal gives its input to.

package Synapse.Pipeline.System_Terminal is

   package Ended_Maps is new Ada.Containers.Ordered_Maps
     (Terminal_Process.Handle, Integer, "<" => Terminal_Process."<");

   --  What Windows keeps of a program that is going: its handle, and the
   --  handle of the job that holds it and whatever it starts.
   type Live_Process is record
      Process : System.Address := System.Null_Address;
      Job     : System.Address := System.Null_Address;
   end record;

   package Live_Maps is new Ada.Containers.Ordered_Maps
     (Terminal_Process.Handle, Live_Process, "<" => Terminal_Process."<");

   --  The system gives a program's end once, so what it said is kept.
   type System_Terminal is limited new Terminal_Process.Terminal with record
      Ended : Ended_Maps.Map;

      --  Where the system keeps programs: the ones that are going.
      Live  : Live_Maps.Map;

      --  The modes the console had before a program that changes them was
      --  started, given back when it ends; below zero when there are none.
      Console_Input  : Integer := -1;
      Console_Output : Integer := -1;
   end record;

   overriding
   function Start
     (T       : in out System_Terminal;
      Request : Session_Process.Process_Request)
      return Terminal_Process.Launch;

   overriding
   function Look
     (T  : in out System_Terminal;
      Id : Terminal_Process.Handle) return Terminal_Process.Progress;

   overriding
   procedure Stop
     (T  : in out System_Terminal;
      Id : Terminal_Process.Handle);

end Synapse.Pipeline.System_Terminal;
