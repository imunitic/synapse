with Ada.Strings.Unbounded;

with Synapse.Pipeline.Patches;
with Synapse.Pipeline.Recorders;
with Synapse.Pipeline.Session_Runner;
with Synapse.Pipeline.Sessions;
with Synapse.Pipeline.Working_Trees;

--  A runner that runs its inner runner and keeps a record of each session.
--  Every request it passes on names the execution it belongs to, so the inner
--  runner can keep the session's transcript there. Every session begins with
--  a `session.started` event: the step, the attempt, the visit, where the
--  runner will write its transcript and the snapshot taken before it (null
--  when there is none). A runner that writes no transcript there leaves the
--  file missing. Every session ends in a `session.finished` event: the step,
--  the attempt, whether it succeeded and where its transcript is. A step with
--  retries has one such pair of events for each try.
--
--  When it is given working trees it takes a snapshot of the folder the
--  session works in before the session and another after it, and keeps what
--  changed between them as the session's patch, `Visit-Step-Attempt.patch`,
--  with the content of a new file kept only up to Largest bytes. A session
--  that changed nothing, a folder that is not in a git repository and a
--  snapshot that could not be taken leave no patch.
--
--  The before snapshot of the run's first session that has one is the
--  run's start: it is pinned as Run_Ref (Id, "start"), so git gc keeps it,
--  and recorded in the summary. Finish does the same for the run's end.

package Synapse.Pipeline.Recording_Runners is

   type Recording_Runner
     (Inner    : not null access Session_Runner.Runner'Class;
      Recorder : not null access Recorders.Recorder;
      Trees    : access Working_Trees.Working_Tree'Class)
   is limited new Session_Runner.Runner with record
      --  The execution the sessions belong to.
      Id      : Ada.Strings.Unbounded.Unbounded_String;

      --  The most bytes of a new file a patch keeps.
      Largest : Natural := Patches.Default_Largest;

      --  The attempt of the last session it ran, 0 before the first. After
      --  a step runs to success it is the attempt the run routed on, since
      --  the engine stops retrying at the first attempt it accepts.
      Last_Attempt : Natural := 0;

      --  Whether the run's start snapshot is pinned and recorded.
      Start_Pinned : Boolean := False;
   end record;

   --  What names the snapshots of a session of Request in the run Id: the run,
   --  the visit and the attempt, with only the characters a file name may
   --  have.
   function Label (Id : String; Request : Sessions.Session_Request)
      return String;

   overriding
   function Run_Session
     (R       : in out Recording_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result;

   --  The run has ended, completed or failed: takes a snapshot of Directory,
   --  the folder the run works in, pins it as Run_Ref (Id, "end") and
   --  records it as the run's end. Does nothing when there are no working
   --  trees, when no start was pinned or when the snapshot is not found.
   procedure Finish (R : in out Recording_Runner; Directory : String);

end Synapse.Pipeline.Recording_Runners;
