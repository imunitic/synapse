with Ada.Strings.Unbounded;

with Synapse.Ports.Variables;
with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Session_Process;
with Synapse.Pipeline.Session_Runner;
with Synapse.Pipeline.Sessions;
with Synapse.Pipeline.Terminal_Process;

--  Runs a session as an interactive process of the step's harness, on the
--  terminal the pipeline was given. The harness is started with the step's
--  prompt as its first message and left to work; a person may type to it
--  whenever they like. The session ends when the agent finishes a turn with a
--  message that is a valid result: the harness is then stopped and the result
--  is what the session came to.
--
--  The runner reads the result from the transcript the harness writes. A turn
--  that ends in anything else is the agent handing control back to the
--  person, which the observer is told of; it is told again when the next
--  turn begins. A harness that ends without a valid result, or runs past the
--  step's time limit, is a failure.

package Synapse.Pipeline.Interactive_Runners is

   --  Told when a session starts waiting for a person and when it stops.
   type Attention_Observer is limited interface;

   --  The agent has handed control to the person; Reason is what it said.
   procedure Waiting
     (O : in out Attention_Observer; Step, Reason : String) is abstract;

   --  The agent is working again.
   procedure Resumed (O : in out Attention_Observer; Step : String)
   is abstract;

   type Interactive_Runner
     (Process  : not null access Session_Process.Process'Class;
      Terminal : not null access Terminal_Process.Terminal'Class;
      Files    : not null access File_System.File_System'Class;
      Registry : not null access Registry_Store.Store'Class)
   is limited new Session_Runner.Runner with record
      --  The home directory of the user, where a harness keeps its sessions.
      Home        : Ada.Strings.Unbounded.Unbounded_String;

      --  Told of a session waiting for a person; nothing when null.
      Observer    : access Attention_Observer'Class;

      --  How often the transcript is looked at.
      Poll        : Duration := 1.0;

      --  The id a session is given; one is drawn when empty.
      Session_Id  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  The home directory of the user: HOME, or USERPROFILE where there is
   --  none, which is where Windows keeps it. Empty when neither is set.
   function Home_Of
     (V : Synapse.Ports.Variables.Variables'Class)
      return Ada.Strings.Unbounded.Unbounded_String;

   overriding
   function Run_Session
     (R       : in out Interactive_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result;

end Synapse.Pipeline.Interactive_Runners;
