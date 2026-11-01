with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;

--  How a running pipeline is reached from outside: a place to listen, where
--  each client sends one request and is given one answer. Where that place is,
--  a socket in a directory or a named pipe, is the implementation's, and
--  nothing above this port can tell.
--
--  Implementations: System_Inspector for the machine the program runs on, and
--  Fake_Transport for tests.

package Synapse.Pipeline.Inspector_Transport is

   --  Whatever answers a request. It is asked from the serving task, one
   --  request at a time.
   type Request_Handler is limited interface;

   function Respond
     (H : in out Request_Handler; Request : String) return String
   is abstract;

   type Transport is limited interface;

   --  Where the run called Id listens, given the directory the program keeps
   --  its work in. The directory the endpoint is in is made if it is not
   --  there.
   function Endpoint_For
     (T : Transport; Work_Directory, Id : String) return String is abstract;

   --  Begins listening at Endpoint. Listening is False, and Reason says why,
   --  when it cannot.
   procedure Listen
     (T         : in out Transport;
      Endpoint  : String;
      Listening : out Boolean;
      Reason    : out Ada.Strings.Unbounded.Unbounded_String) is abstract;

   --  Answers clients one at a time, each with the handler's answer to the one
   --  request it sends, until Stop says to. A client that is slow, silent or
   --  gone is let go and the next is taken.
   procedure Serve
     (T    : in out Transport;
      H    : in out Request_Handler'Class;
      Stop : not null access function return Boolean) is abstract;

   --  Stops listening and removes the endpoint.
   procedure Close (T : in out Transport) is abstract;

   --  The ids of the runs that may be listening for Work_Directory, in
   --  alphabetical order. They are found, not asked: one may be left over from
   --  a run that did not get to clean up.
   function Ids
     (T : Transport; Work_Directory : String)
      return Synapse.Core.Text_Lists.Vector is abstract;

   --  Sends one request to what listens at Endpoint and waits for the one
   --  answer. Answered is False when there is none, because nothing listens
   --  there or what does is silent, and Answer then says why.
   procedure Ask
     (T         : Transport;
      Endpoint  : String;
      Request   : String;
      Answered  : out Boolean;
      Answer    : out Ada.Strings.Unbounded.Unbounded_String) is abstract;

end Synapse.Pipeline.Inspector_Transport;
