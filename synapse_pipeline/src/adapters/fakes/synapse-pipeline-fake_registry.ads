with Ada.Calendar;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Registry_Store;

--  A registry held in memory, for tests. An operation can be made to fail, for
--  a number of attempts or for good, and every attempt is counted.

package Synapse.Pipeline.Fake_Registry is

   type Operation is
     (Create_Op, Replace_Op, Append_Op, Transcript_Op, Remove_Op);

   package Contents is new Ada.Containers.Indefinite_Ordered_Maps
     (String, String);

   type Execution is record
      Summary     : Ada.Strings.Unbounded.Unbounded_String;
      Has_Summary : Boolean := False;
      Events      : Ada.Strings.Unbounded.Unbounded_String;
      Has_Events  : Boolean := False;
      Transcripts : Contents.Map;
      Written     : Ada.Calendar.Time := Ada.Calendar.Clock;
   end record;

   package Executions is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Execution);

   type Counts is array (Operation) of Natural;

   type Fake_Registry is limited new Registry_Store.Store with record
      Held     : Executions.Map;

      --  What Open was last told.
      Work     : Ada.Strings.Unbounded.Unbounded_String;
      Failing  : Counts := [others => 0];
      Attempts : Counts := [others => 0];
   end record;

   overriding
   procedure Open (F : in out Fake_Registry; Work_Directory : String);

   --  Makes the next Times attempts of Op fail.
   procedure Fail
     (F : in out Fake_Registry; Op : Operation; Times : Natural := 1_000_000);

   --  Lets Op work again.
   procedure Mend (F : in out Fake_Registry; Op : Operation);

   --  Sets the time the summary of Id counts as last written.
   procedure Set_Last_Write
     (F : in out Fake_Registry; Id : String; At_Time : Ada.Calendar.Time);

   overriding
   function Create
     (F : in out Fake_Registry; Id : String)
      return Registry_Store.Create_Result;

   overriding
   function Replace_Summary
     (F : in out Fake_Registry; Id, Content : String) return Boolean;

   overriding
   function Append_Event
     (F : in out Fake_Registry; Id, Line : String) return Boolean;

   overriding
   function Write_Transcript
     (F : in out Fake_Registry; Id, Name, Content : String) return Boolean;

   overriding
   function Remove (F : in out Fake_Registry; Id : String) return Boolean;

   overriding
   function Ids (F : Fake_Registry) return Synapse.Core.Text_Lists.Vector;

   overriding
   function Read_Summary
     (F : Fake_Registry; Id : String) return Registry_Store.Maybe_Content;

   overriding
   function Read_Events
     (F : Fake_Registry; Id : String) return Registry_Store.Maybe_Content;

   overriding
   function Transcript_Path
     (F : Fake_Registry; Id, Name : String) return String;

   overriding
   function Transcript_Names
     (F : Fake_Registry; Id : String) return Synapse.Core.Text_Lists.Vector;

   overriding
   function Last_Write
     (F : Fake_Registry; Id : String)
      return Registry_Store.Time_Options.Option;

end Synapse.Pipeline.Fake_Registry;
