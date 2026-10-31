with Ada.Strings.Unbounded;

with GNAT.Sockets;

with Synapse.Core.Text_Lists;

with Synapse.Pipeline.Inspector_Transport;

--  The inspector's transport on the machine the program runs on. On a POSIX
--  system it is a Unix domain socket in a directory only the user can enter:
--  `<work directory>/pipelines/<id>.sock`. Where there is nothing to listen
--  with, listening reports that and the run goes on without.

package Synapse.Pipeline.System_Inspector is

   type System_Transport is limited new Inspector_Transport.Transport
   with private;

   overriding
   function Endpoint_For
     (T : System_Transport; Work_Directory, Id : String) return String;

   overriding
   procedure Listen
     (T         : in out System_Transport;
      Endpoint  : String;
      Listening : out Boolean;
      Reason    : out Ada.Strings.Unbounded.Unbounded_String);

   overriding
   procedure Serve
     (T    : in out System_Transport;
      H    : in out Inspector_Transport.Request_Handler'Class;
      Stop : not null access function return Boolean);

   overriding
   procedure Close (T : in out System_Transport);

   overriding
   function Ids
     (T : System_Transport; Work_Directory : String)
      return Synapse.Core.Text_Lists.Vector;

   overriding
   procedure Ask
     (T         : System_Transport;
      Endpoint  : String;
      Request   : String;
      Answered  : out Boolean;
      Answer    : out Ada.Strings.Unbounded.Unbounded_String);

   --  The longest endpoint a Unix socket can be given, with room to spare
   --  under the operating systems' own limits (104 bytes on macOS, 108 on
   --  Linux).
   Max_Endpoint_Length : constant := 100;

private

   type System_Transport is limited new Inspector_Transport.Transport with
   record
      Endpoint  : Ada.Strings.Unbounded.Unbounded_String;
      Listening : Boolean := False;
      Server    : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
   end record;

end Synapse.Pipeline.System_Inspector;
