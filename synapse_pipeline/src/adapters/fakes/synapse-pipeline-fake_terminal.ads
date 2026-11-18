with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Fake_Process;
with Synapse.Pipeline.Session_Process;
with Synapse.Pipeline.Terminal_Process;

--  A terminal that runs nothing. It records the program it is asked to start,
--  and each time it is looked at it does what it was told to do at that look:
--  append to a file, as a harness writing its transcript would, and perhaps
--  end.

package Synapse.Pipeline.Fake_Terminal is

   type Tick is record
      --  The file to append Text to; empty appends nothing.
      Path  : Ada.Strings.Unbounded.Unbounded_String;
      Text  : Ada.Strings.Unbounded.Unbounded_String;

      --  The program ends at this look, with Code.
      Ends  : Boolean := False;
      Code  : Integer := 0;
   end record;

   package Tick_Vectors is new Ada.Containers.Vectors (Positive, Tick);

   type Fake_Terminal is limited new Terminal_Process.Terminal with record
      --  The file system the ticks write into.
      Files    : access Fake_Files.Fake_Files;

      Requests : Fake_Process.Request_Vectors.Vector;

      --  When not empty, the program cannot be started, for this reason.
      Refusal  : Ada.Strings.Unbounded.Unbounded_String;

      --  The first look does the first tick, the second the second, and a
      --  look past the last does nothing.
      Ticks    : Tick_Vectors.Vector;

      Looks    : Natural := 0;
      Stopped  : Boolean := False;
   end record;

   overriding
   function Start
     (T       : in out Fake_Terminal;
      Request : Session_Process.Process_Request)
      return Terminal_Process.Launch;

   overriding
   function Look
     (T  : in out Fake_Terminal;
      Id : Terminal_Process.Handle) return Terminal_Process.Progress;

   overriding
   procedure Stop
     (T  : in out Fake_Terminal;
      Id : Terminal_Process.Handle);

end Synapse.Pipeline.Fake_Terminal;
