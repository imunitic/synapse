with Ada.Containers.Indefinite_Ordered_Sets;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Registry_Store;

--  A registry that tries again. Each write is attempted up to Attempts times,
--  with a pause that starts at First_Pause and doubles, about 150 ms in all.
--  When every attempt fails the write is given up and Warn is told, once for
--  each execution however many of its writes fail; the next write gets its own
--  attempts, so a failure that passes does not end the record. Reading is not
--  retried.
--
--  The pause and the warning are given in, so a test runs the retries without
--  waiting and sees what was said.

package Synapse.Pipeline.Retrying_Registry is

   Attempts    : constant := 5;
   First_Pause : constant Duration := 0.010;

   package Names is new Ada.Containers.Indefinite_Ordered_Sets (String);

   type Retrying_Registry
     (Inner : not null access Registry_Store.Store'Class;
      Pause : not null access procedure (Seconds : Duration);
      Warn  : not null access procedure (Message : String))
   is limited new Registry_Store.Store with record
      Warned : Names.Set;
   end record;

   overriding
   procedure Open (R : in out Retrying_Registry; Work_Directory : String);

   overriding
   function Create
     (R : in out Retrying_Registry; Id : String)
      return Registry_Store.Create_Result;

   overriding
   function Replace_Summary
     (R : in out Retrying_Registry; Id, Content : String) return Boolean;

   overriding
   function Append_Event
     (R : in out Retrying_Registry; Id, Line : String) return Boolean;

   overriding
   function Write_Transcript
     (R : in out Retrying_Registry; Id, Name, Content : String) return Boolean;

   overriding
   function Write_Description
     (R : in out Retrying_Registry; Id, Content : String) return Boolean;

   overriding
   function Write_Definition
     (R : in out Retrying_Registry; Id, Path, Content : String) return Boolean;

   overriding
   function Remove (R : in out Retrying_Registry; Id : String) return Boolean;

   overriding
   function Ids (R : Retrying_Registry) return Synapse.Core.Text_Lists.Vector;

   overriding
   function Read_Summary
     (R : Retrying_Registry; Id : String) return Registry_Store.Maybe_Content;

   overriding
   function Read_Events
     (R : Retrying_Registry; Id : String) return Registry_Store.Maybe_Content;

   overriding
   function Read_Description
     (R : Retrying_Registry; Id : String) return Registry_Store.Maybe_Content;

   overriding
   function Read_Definition
     (R : Retrying_Registry; Id, Path : String)
      return Registry_Store.Maybe_Content;

   overriding
   function Transcript_Path
     (R : Retrying_Registry; Id, Name : String) return String;

   overriding
   function Transcript_Names
     (R : Retrying_Registry; Id : String)
      return Synapse.Core.Text_Lists.Vector;

   overriding
   function Last_Write
     (R : Retrying_Registry; Id : String)
      return Registry_Store.Time_Options.Option;

end Synapse.Pipeline.Retrying_Registry;
