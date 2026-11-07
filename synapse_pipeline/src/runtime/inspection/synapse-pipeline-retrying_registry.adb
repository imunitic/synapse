package body Synapse.Pipeline.Retrying_Registry is

   use type Registry_Store.Create_Result;

   --  Says once for each execution that its record could not be kept.
   procedure Give_Up
     (R : in out Retrying_Registry; Id, What : String) is
   begin
      if not R.Warned.Contains (Id) then
         R.Warned.Insert (Id);
         R.Warn
           ("the record of execution " & Id & " could not be written ("
            & What & "); the run goes on without it");
      end if;
   end Give_Up;

   --  Tries Attempt until it says it worked, up to Attempts times.
   function Try
     (R       : in out Retrying_Registry;
      Id      : String;
      What    : String;
      Attempt : not null access function return Boolean) return Boolean
   is
      Wait : Duration := First_Pause;
   begin
      for Number in 1 .. Attempts loop
         if Attempt.all then
            return True;
         end if;
         if Number < Attempts then
            R.Pause (Wait);
            Wait := Wait * 2;
         end if;
      end loop;
      Give_Up (R, Id, What);
      return False;
   end Try;

   overriding
   procedure Open (R : in out Retrying_Registry; Work_Directory : String) is
   begin
      R.Inner.Open (Work_Directory);
   end Open;

   overriding
   function Create
     (R : in out Retrying_Registry; Id : String)
      return Registry_Store.Create_Result
   is
      Result : Registry_Store.Create_Result := Registry_Store.Failed;

      --  A taken id is an answer, not a failure, so only a failure is tried
      --  again.
      function Once return Boolean is
      begin
         Result := R.Inner.Create (Id);
         return Result /= Registry_Store.Failed;
      end Once;

      Done : constant Boolean := Try (R, Id, "its directory", Once'Access);
      pragma Unreferenced (Done);
   begin
      return Result;
   end Create;

   overriding
   function Replace_Summary
     (R : in out Retrying_Registry; Id, Content : String) return Boolean
   is
      function Once return Boolean is (R.Inner.Replace_Summary (Id, Content));
   begin
      return Try (R, Id, "its summary", Once'Access);
   end Replace_Summary;

   overriding
   function Append_Event
     (R : in out Retrying_Registry; Id, Line : String) return Boolean
   is
      function Once return Boolean is (R.Inner.Append_Event (Id, Line));
   begin
      return Try (R, Id, "an event", Once'Access);
   end Append_Event;

   overriding
   function Write_Transcript
     (R : in out Retrying_Registry; Id, Name, Content : String) return Boolean
   is
      function Once return Boolean is
        (R.Inner.Write_Transcript (Id, Name, Content));
   begin
      return Try (R, Id, "the transcript " & Name, Once'Access);
   end Write_Transcript;

   overriding
   function Write_Description
     (R : in out Retrying_Registry; Id, Content : String) return Boolean
   is
      function Once return Boolean is
        (R.Inner.Write_Description (Id, Content));
   begin
      return Try (R, Id, "its description", Once'Access);
   end Write_Description;

   overriding
   function Write_Definition
     (R : in out Retrying_Registry; Id, Path, Content : String) return Boolean
   is
      function Once return Boolean is
        (R.Inner.Write_Definition (Id, Path, Content));
   begin
      --  A path that is refused is refused every time, so it is not tried
      --  again.
      if not Registry_Store.Is_Plain_Path (Path) then
         return False;
      end if;
      return Try (R, Id, "the definition " & Path, Once'Access);
   end Write_Definition;

   overriding
   function Remove (R : in out Retrying_Registry; Id : String) return Boolean
   is
      function Once return Boolean is (R.Inner.Remove (Id));
   begin
      return Try (R, Id, "its removal", Once'Access);
   end Remove;

   overriding
   function Ids (R : Retrying_Registry) return Synapse.Core.Text_Lists.Vector
   is
   begin
      return R.Inner.Ids;
   end Ids;

   overriding
   function Read_Summary
     (R : Retrying_Registry; Id : String) return Registry_Store.Maybe_Content
   is
   begin
      return R.Inner.Read_Summary (Id);
   end Read_Summary;

   overriding
   function Read_Events
     (R : Retrying_Registry; Id : String) return Registry_Store.Maybe_Content
   is
   begin
      return R.Inner.Read_Events (Id);
   end Read_Events;

   overriding
   function Read_Description
     (R : Retrying_Registry; Id : String) return Registry_Store.Maybe_Content
   is
   begin
      return R.Inner.Read_Description (Id);
   end Read_Description;

   overriding
   function Read_Definition
     (R : Retrying_Registry; Id, Path : String)
      return Registry_Store.Maybe_Content
   is
   begin
      return R.Inner.Read_Definition (Id, Path);
   end Read_Definition;

   overriding
   function Transcript_Path
     (R : Retrying_Registry; Id, Name : String) return String is
   begin
      return R.Inner.Transcript_Path (Id, Name);
   end Transcript_Path;

   overriding
   function Transcript_Names
     (R : Retrying_Registry; Id : String)
      return Synapse.Core.Text_Lists.Vector
   is
   begin
      return R.Inner.Transcript_Names (Id);
   end Transcript_Names;

   overriding
   function Last_Write
     (R : Retrying_Registry; Id : String)
      return Registry_Store.Time_Options.Option
   is
   begin
      return R.Inner.Last_Write (Id);
   end Last_Write;

end Synapse.Pipeline.Retrying_Registry;
