
with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Sessions;

--  What a runner of sessions does the same way however the session is run:
--  the prompt a step is started with, the environment it runs in, a failure
--  in the shape the engine reads, the transcript kept in the registry, and an
--  answer read as the envelope.

package Synapse.Pipeline.Session_Support is

   --  The failure of the session of Request, with the step named.
   function Failed_Session
     (Request : Sessions.Session_Request;
      Kind    : Failures.Failure_Kind;
      Message : String;
      Used    : Sessions.Usage_Report := (others => <>))
      return Sessions.Session_Result;

   --  Item, with Transcript as the file its transcript was kept in.
   function With_Transcript
     (Item       : Sessions.Session_Result;
      Transcript : Synapse.Core.Optional_Text.Option)
      return Sessions.Session_Result;

   --  The file name the transcript of the session of Request is kept under:
   --  `<visit>-<step>-<attempt>.jsonl`.
   function Transcript_Name
     (Request : Sessions.Session_Request) return String;

   --  Creates the transcript of the session of Request empty, so a runner can
   --  write into it while the session runs, and says where it is. Empty when
   --  the request names no execution or the file could not be made.
   function Begin_Transcript
     (Registry : in out Registry_Store.Store'Class;
      Request  : Sessions.Session_Request) return String;

   --  Keeps Output as the transcript of the session of Request, when there is
   --  an execution to keep it under, and says where it went.
   function Keep_Transcript
     (Registry : in out Registry_Store.Store'Class;
      Request  : Sessions.Session_Request;
      Output   : String) return Synapse.Core.Optional_Text.Option;

   --  An answer without the code fence a model sometimes puts round it.
   function Unfenced (Text : String) return String;

   --  The prompt the session of Request is started with: the step's role and
   --  assignment as they were resolved, and what every step is told.
   --  Interactive is whether a person can answer.
   function Prompt_Of
     (Request     : Sessions.Session_Request;
      Interactive : Boolean) return String;

   --  Adds the variables the configuration gives sessions to Into, as
   --  `NAME=value`.
   procedure Add_Settings
     (Into     : in out Synapse.Core.Text_Lists.Vector;
      Settings : Configs.Config);

end Synapse.Pipeline.Session_Support;
