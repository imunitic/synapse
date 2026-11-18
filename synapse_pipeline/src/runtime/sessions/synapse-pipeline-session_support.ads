with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Search_Paths;
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

   --  Keeps Output as the transcript of the session of Request, when there is
   --  an execution to keep it under, and says where it went.
   function Keep_Transcript
     (Registry : in out Registry_Store.Store'Class;
      Request  : Sessions.Session_Request;
      Output   : String) return Synapse.Core.Optional_Text.Option;

   --  An answer without the code fence a model sometimes puts round it.
   function Unfenced (Text : String) return String;

   --  The prompt the session of Request is started with, and the directory of
   --  the skill the step names, empty when it names none. Problem is empty
   --  unless a skill or its text could not be had, and then says why and the
   --  rest is not to be used. Interactive is whether a person can answer.
   procedure Prepare
     (Files           : File_System.File_System'Class;
      Skill_Roots     : Search_Paths.Root_Vectors.Vector;
      Request         : Sessions.Session_Request;
      Interactive     : Boolean;
      Prompt          : out Ada.Strings.Unbounded.Unbounded_String;
      Skill_Directory : out Ada.Strings.Unbounded.Unbounded_String;
      Problem         : out Ada.Strings.Unbounded.Unbounded_String);

   --  Adds the variables the configuration gives sessions to Into, as
   --  `NAME=value`.
   procedure Add_Settings
     (Into     : in out Synapse.Core.Text_Lists.Vector;
      Settings : Configs.Config);

end Synapse.Pipeline.Session_Support;
