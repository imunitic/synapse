with Synapse.Pipeline.Sessions;

--  What runs an agent session. The engine asks for one session at a time and
--  gets back a checked result or a failure; how the session is run, as a
--  process of a harness or from a script, is the implementation's business
--  and the engine cannot tell. A runner is changed by running, which is why a
--  session is run through a variable parameter: a scripted one uses up its
--  script.

package Synapse.Pipeline.Session_Runner is

   type Runner is limited interface;

   --  Runs one bounded session to its end and says how it ended. The result
   --  of a success has already passed the envelope's checks. A session that
   --  runs past the request's timeout is stopped and fails; one that cannot be
   --  run at all fails too. Neither raises.
   function Run_Session
     (R       : in out Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result
   is abstract;

end Synapse.Pipeline.Session_Runner;
