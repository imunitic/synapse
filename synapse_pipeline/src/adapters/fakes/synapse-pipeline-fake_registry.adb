package body Synapse.Pipeline.Fake_Registry is

   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;

   overriding
   procedure Open (F : in out Fake_Registry; Work_Directory : String) is
   begin
      F.Work := To_Unbounded_String (Work_Directory);
   end Open;

   procedure Fail
     (F : in out Fake_Registry; Op : Operation; Times : Natural := 1_000_000)
   is
   begin
      F.Failing (Op) := Times;
   end Fail;

   procedure Mend (F : in out Fake_Registry; Op : Operation) is
   begin
      F.Failing (Op) := 0;
   end Mend;

   --  Counts the attempt and says whether it is to fail.
   function Attempt (F : in out Fake_Registry; Op : Operation) return Boolean
   is
   begin
      F.Attempts (Op) := F.Attempts (Op) + 1;
      if F.Failing (Op) > 0 then
         F.Failing (Op) := F.Failing (Op) - 1;
         return False;
      end if;
      return True;
   end Attempt;

   procedure Set_Last_Write
     (F : in out Fake_Registry; Id : String; At_Time : Ada.Calendar.Time)
   is
      Place : constant Executions.Cursor := F.Held.Find (Id);
   begin
      if Executions.Has_Element (Place) then
         declare
            Item : Execution := Executions.Element (Place);
         begin
            Item.Written := At_Time;
            F.Held.Replace_Element (Place, Item);
         end;
      end if;
   end Set_Last_Write;

   overriding
   function Create
     (F : in out Fake_Registry; Id : String)
      return Registry_Store.Create_Result
   is
   begin
      if not Attempt (F, Create_Op) then
         return Registry_Store.Failed;
      elsif F.Held.Contains (Id) then
         return Registry_Store.Already_Exists;
      end if;
      F.Held.Insert (Id, Execution'(others => <>));
      return Registry_Store.Created;
   end Create;

   --  Changes the execution Id by Change, when there is one.
   procedure Update
     (F      : in out Fake_Registry; Id : String;
      Change : not null access procedure (Item : in out Execution);
      Found  : out Boolean)
   is
      Place : constant Executions.Cursor := F.Held.Find (Id);
   begin
      Found := Executions.Has_Element (Place);
      if Found then
         declare
            Item : Execution := Executions.Element (Place);
         begin
            Change (Item);
            F.Held.Replace_Element (Place, Item);
         end;
      end if;
   end Update;

   overriding
   function Replace_Summary
     (F : in out Fake_Registry; Id, Content : String) return Boolean
   is
      Found : Boolean;

      procedure Change (Item : in out Execution) is
      begin
         Item.Summary := To_Unbounded_String (Content);
         Item.Has_Summary := True;
         Item.Written := Ada.Calendar.Clock;
      end Change;
   begin
      if not Attempt (F, Replace_Op) then
         return False;
      end if;
      Update (F, Id, Change'Access, Found);
      return Found;
   end Replace_Summary;

   overriding
   function Append_Event
     (F : in out Fake_Registry; Id, Line : String) return Boolean
   is
      Found : Boolean;

      procedure Change (Item : in out Execution) is
      begin
         Append (Item.Events, Line & Character'Val (10));
         Item.Has_Events := True;
      end Change;
   begin
      if not Attempt (F, Append_Op) then
         return False;
      end if;
      Update (F, Id, Change'Access, Found);
      return Found;
   end Append_Event;

   overriding
   function Write_Transcript
     (F : in out Fake_Registry; Id, Name, Content : String) return Boolean
   is
      Found : Boolean;

      procedure Change (Item : in out Execution) is
      begin
         Item.Transcripts.Include (Name, Content);
      end Change;
   begin
      if not Attempt (F, Transcript_Op) then
         return False;
      end if;
      Update (F, Id, Change'Access, Found);
      return Found;
   end Write_Transcript;

   overriding
   function Write_Description
     (F : in out Fake_Registry; Id, Content : String) return Boolean
   is
      Found : Boolean;

      procedure Change (Item : in out Execution) is
      begin
         Item.Description := To_Unbounded_String (Content);
         Item.Has_Description := True;
      end Change;
   begin
      if not Attempt (F, Description_Op) then
         return False;
      end if;
      Update (F, Id, Change'Access, Found);
      return Found;
   end Write_Description;

   overriding
   function Write_Definition
     (F : in out Fake_Registry; Id, Path, Content : String) return Boolean
   is
      Found : Boolean;

      procedure Change (Item : in out Execution) is
      begin
         Item.Definitions.Include (Path, Content);
      end Change;
   begin
      if not Attempt (F, Definition_Op) then
         return False;
      end if;
      if not Registry_Store.Is_Plain_Path (Path) then
         return False;
      end if;
      Update (F, Id, Change'Access, Found);
      return Found;
   end Write_Definition;

   overriding
   function Remove (F : in out Fake_Registry; Id : String) return Boolean is
   begin
      if not Attempt (F, Remove_Op) then
         return False;
      end if;
      F.Held.Exclude (Id);
      return True;
   end Remove;

   overriding
   function Ids (F : Fake_Registry) return Synapse.Core.Text_Lists.Vector is
      Result : Synapse.Core.Text_Lists.Vector;
   begin
      for Place in F.Held.Iterate loop
         Result.Append (To_Unbounded_String (Executions.Key (Place)));
      end loop;
      return Result;
   end Ids;

   overriding
   function Read_Summary
     (F : Fake_Registry; Id : String) return Registry_Store.Maybe_Content
   is
      Place : constant Executions.Cursor := F.Held.Find (Id);
   begin
      if Executions.Has_Element (Place)
        and then Executions.Element (Place).Has_Summary
      then
         return Registry_Store.Maybe_Content'
           (Found => True, Value => Executions.Element (Place).Summary);
      end if;
      return Registry_Store.Maybe_Content'(Found => False);
   end Read_Summary;

   overriding
   function Read_Events
     (F : Fake_Registry; Id : String) return Registry_Store.Maybe_Content
   is
      Place : constant Executions.Cursor := F.Held.Find (Id);
   begin
      if Executions.Has_Element (Place)
        and then Executions.Element (Place).Has_Events
      then
         return Registry_Store.Maybe_Content'
           (Found => True, Value => Executions.Element (Place).Events);
      end if;
      return Registry_Store.Maybe_Content'(Found => False);
   end Read_Events;

   overriding
   function Read_Description
     (F : Fake_Registry; Id : String) return Registry_Store.Maybe_Content
   is
      Place : constant Executions.Cursor := F.Held.Find (Id);
   begin
      if Executions.Has_Element (Place)
        and then Executions.Element (Place).Has_Description
      then
         return Registry_Store.Maybe_Content'
           (Found => True, Value => Executions.Element (Place).Description);
      end if;
      return Registry_Store.Maybe_Content'(Found => False);
   end Read_Description;

   overriding
   function Read_Definition
     (F : Fake_Registry; Id, Path : String) return Registry_Store.Maybe_Content
   is
      Place : constant Executions.Cursor := F.Held.Find (Id);
   begin
      if Executions.Has_Element (Place)
        and then Registry_Store.Is_Plain_Path (Path)
      then
         declare
            Item : constant Execution := Executions.Element (Place);
            Held : constant Contents.Cursor := Item.Definitions.Find (Path);
         begin
            if Contents.Has_Element (Held) then
               return Registry_Store.Maybe_Content'
                 (Found => True,
                  Value => To_Unbounded_String (Contents.Element (Held)));
            end if;
         end;
      end if;
      return Registry_Store.Maybe_Content'(Found => False);
   end Read_Definition;

   overriding
   function Transcript_Path
     (F : Fake_Registry; Id, Name : String) return String
   is
      pragma Unreferenced (F);
   begin
      return "memory:" & Id & "/transcripts/" & Name;
   end Transcript_Path;

   overriding
   function Transcript_Names
     (F : Fake_Registry; Id : String) return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
      Place  : constant Executions.Cursor := F.Held.Find (Id);
   begin
      if Executions.Has_Element (Place) then
         declare
            Item : constant Execution := Executions.Element (Place);
         begin
            for Held in Item.Transcripts.Iterate loop
               Result.Append (To_Unbounded_String (Contents.Key (Held)));
            end loop;
         end;
      end if;
      return Result;
   end Transcript_Names;

   overriding
   function Last_Write
     (F : Fake_Registry; Id : String) return Registry_Store.Time_Options.Option
   is
      Place : constant Executions.Cursor := F.Held.Find (Id);
   begin
      if Executions.Has_Element (Place)
        and then Executions.Element (Place).Has_Summary
      then
         return Registry_Store.Time_Options.Of_Value
           (Executions.Element (Place).Written);
      end if;
      return Registry_Store.Time_Options.None;
   end Last_Write;

end Synapse.Pipeline.Fake_Registry;
