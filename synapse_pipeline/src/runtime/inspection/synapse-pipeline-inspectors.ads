with Synapse.Pipeline.Contexts;
with Synapse.Pipeline.Inspector_Transport;

--  Answering questions about a run while it goes on. The run is a task of its
--  own and asks nothing of this: the inspector only ever reads a snapshot of
--  the execution context and writes to a client, so whatever goes wrong in it
--  — a place to listen that cannot be had, a client that misbehaves, an
--  exception in the serving task — stops the answering and never the run.

package Synapse.Pipeline.Inspectors is

   --  A fresh identity for a run, `exec-` and eight hexadecimal digits.
   function New_Id return String;

   --  Runs Action, once, with the context answered at Endpoint for as long as
   --  Action takes. Action is told whether the inspector got going and, when
   --  it did not, why; it runs either way. Whatever Action raises is raised
   --  again once the inspector has stopped.
   procedure Serve_While
     (Transport : in out Inspector_Transport.Transport'Class;
      Endpoint  : String;
      Context   : aliased in out Contexts.Execution_Context;
      Action    : not null access procedure
        (Listening : Boolean; Reason : String));

end Synapse.Pipeline.Inspectors;
