with Ada.Calendar;

with Synapse.Core.Optional_Text;
with Synapse.Core.Options;
with Synapse.Core.Text_Lists;

--  Where the record of each execution is kept: one directory per execution,
--  holding its summary, its event history and one transcript per step attempt.
--  Everything that writes or reads that record goes through this port, so the
--  disk is reached in one place and a test can stand in for it.
--
--  Writing is best effort. An operation that cannot do its work says so and
--  never raises, and what calls it goes on. Implementations are Disk_Registry
--  for the machine the program runs on, Fake_Registry for tests, and
--  Retrying_Registry, which wraps either and tries again.

package Synapse.Pipeline.Registry_Store is

   --  Whether Create made the execution's directory, found it already there
   --  or could not make it. Already_Exists is not a failure: the id is taken
   --  and the caller draws another.
   type Create_Result is (Created, Already_Exists, Failed);

   subtype Maybe_Content is Synapse.Core.Optional_Text.Option;

   package Time_Options is new Synapse.Core.Options (Ada.Calendar.Time);

   type Store is limited interface;

   --  Tells the store where the program keeps its work. It is told before it
   --  is used, once the run knows it; a store that holds nothing on a disk
   --  has nothing to do.
   procedure Open (S : in out Store; Work_Directory : String) is abstract;

   --  Makes the directory of the execution Id, which only the user may enter.
   --  It does not touch a directory that is already there.
   function Create (S : in out Store; Id : String) return Create_Result
   is abstract;

   --  Replaces the execution's summary with Content, whole: a reader sees the
   --  old summary or the new one and never part of one. True when it was
   --  written.
   function Replace_Summary
     (S : in out Store; Id, Content : String) return Boolean is abstract;

   --  Adds Line, which holds no line break, to the end of the execution's
   --  event history. True when it was written.
   function Append_Event
     (S : in out Store; Id, Line : String) return Boolean is abstract;

   --  Keeps Content as the transcript called Name of the execution, replacing
   --  one of that name. True when it was written.
   function Write_Transcript
     (S : in out Store; Id, Name, Content : String) return Boolean
   is abstract;

   --  Removes the execution's directory and everything in it. True when it
   --  is gone, which includes when it was never there.
   function Remove (S : in out Store; Id : String) return Boolean is abstract;

   --  The ids of the recorded executions, in alphabetical order.
   function Ids (S : Store) return Synapse.Core.Text_Lists.Vector is abstract;

   --  The execution's summary, or nothing when there is none or it cannot be
   --  read.
   function Read_Summary (S : Store; Id : String) return Maybe_Content
   is abstract;

   --  The execution's event history, each event ended by a line break, or
   --  nothing when there is none or it cannot be read.
   function Read_Events (S : Store; Id : String) return Maybe_Content
   is abstract;

   --  Where the transcript called Name of the execution is kept, whether or
   --  not it has been written.
   function Transcript_Path
     (S : Store; Id, Name : String) return String is abstract;

   --  The names of the execution's transcripts, in alphabetical order.
   function Transcript_Names
     (S : Store; Id : String) return Synapse.Core.Text_Lists.Vector
   is abstract;

   --  When the execution's summary was last written, or nothing when it has
   --  none.
   function Last_Write (S : Store; Id : String) return Time_Options.Option
   is abstract;

end Synapse.Pipeline.Registry_Store;
