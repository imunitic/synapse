with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Registry_Store;

--  The registry on the disk of the machine the program runs on:
--  `<work directory>/pipelines/<id>/`, which only the user may enter, holds
--
--    execution.json     the summary, replaced whole
--    events.jsonl       the events, one a line, added to
--    transcripts/       one file a step attempt
--
--  Each operation makes one attempt.

package Synapse.Pipeline.Disk_Registry is

   type Disk_Registry is limited new Registry_Store.Store with private;

   --  Keeps the registry in Work_Directory.
   overriding
   procedure Open (R : in out Disk_Registry; Work_Directory : String);

   --  The directory of the execution Id, whether or not it exists.
   function Directory_Of (R : Disk_Registry; Id : String) return String;

   overriding
   function Create
     (R : in out Disk_Registry; Id : String)
      return Registry_Store.Create_Result;

   overriding
   function Replace_Summary
     (R : in out Disk_Registry; Id, Content : String) return Boolean;

   overriding
   function Append_Event
     (R : in out Disk_Registry; Id, Line : String) return Boolean;

   overriding
   function Write_Transcript
     (R : in out Disk_Registry; Id, Name, Content : String) return Boolean;

   overriding
   function Write_Description
     (R : in out Disk_Registry; Id, Content : String) return Boolean;

   overriding
   function Write_Definition
     (R : in out Disk_Registry; Id, Path, Content : String) return Boolean;

   overriding
   function Remove (R : in out Disk_Registry; Id : String) return Boolean;

   overriding
   function Ids (R : Disk_Registry) return Synapse.Core.Text_Lists.Vector;

   overriding
   function Read_Summary
     (R : Disk_Registry; Id : String) return Registry_Store.Maybe_Content;

   overriding
   function Read_Events
     (R : Disk_Registry; Id : String) return Registry_Store.Maybe_Content;

   overriding
   function Read_Description
     (R : Disk_Registry; Id : String) return Registry_Store.Maybe_Content;

   overriding
   function Read_Definition
     (R : Disk_Registry; Id, Path : String)
      return Registry_Store.Maybe_Content;

   overriding
   function Transcript_Path
     (R : Disk_Registry; Id, Name : String) return String;

   overriding
   function Transcript_Names
     (R : Disk_Registry; Id : String) return Synapse.Core.Text_Lists.Vector;

   overriding
   function Last_Write
     (R : Disk_Registry; Id : String)
      return Registry_Store.Time_Options.Option;

private

   type Disk_Registry is limited new Registry_Store.Store with record
      Root : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Pipeline.Disk_Registry;
