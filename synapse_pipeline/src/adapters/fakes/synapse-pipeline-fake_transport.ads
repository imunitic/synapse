with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Inspection;
with Synapse.Pipeline.Inspector_Transport;

--  A transport that serves requests put in a mailbox, for tests. Serving goes
--  on until it is told to stop, answering each request as it appears.

package Synapse.Pipeline.Fake_Transport is

   protected type Mailbox is
      procedure Put (Request : String);
      procedure Take
        (Request : out Ada.Strings.Unbounded.Unbounded_String;
         Found   : out Boolean);
      procedure Answer (Text : String);
      function Answers return Synapse.Core.Text_Lists.Vector;
      function Answered return Natural;
   private
      Waiting : Synapse.Core.Text_Lists.Vector;
      Given   : Synapse.Core.Text_Lists.Vector;
   end Mailbox;

   package Run_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Inspection.Snapshot, "<", Inspection."=");

   package Id_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   type Fake_Transport is limited new Inspector_Transport.Transport with record
      --  Runs that are listening, by id, and what each would say.
      Runs     : Run_Maps.Map;

      --  Ids whose endpoint is there but is listened at by nothing.
      Stale    : Id_Sets.Set;

      --  Listening fails.
      Refuse   : Boolean := False;

      --  Serving raises.
      Crash    : Boolean := False;

      --  Where it was told to listen, and whether it has been closed.
      Endpoint : Ada.Strings.Unbounded.Unbounded_String;
      Closed   : Boolean := False;
      Box      : Mailbox;
   end record;

   overriding
   function Endpoint_For
     (T : Fake_Transport; Work_Directory, Id : String) return String;

   overriding
   procedure Listen
     (T         : in out Fake_Transport;
      Endpoint  : String;
      Listening : out Boolean;
      Reason    : out Ada.Strings.Unbounded.Unbounded_String);

   overriding
   procedure Serve
     (T    : in out Fake_Transport;
      H    : in out Inspector_Transport.Request_Handler'Class;
      Stop : not null access function return Boolean);

   overriding
   procedure Close (T : in out Fake_Transport);

   overriding
   function Ids
     (T : Fake_Transport; Work_Directory : String)
      return Synapse.Core.Text_Lists.Vector;

   overriding
   procedure Ask
     (T         : Fake_Transport;
      Endpoint  : String;
      Request   : String;
      Answered  : out Boolean;
      Answer    : out Ada.Strings.Unbounded.Unbounded_String);

end Synapse.Pipeline.Fake_Transport;
