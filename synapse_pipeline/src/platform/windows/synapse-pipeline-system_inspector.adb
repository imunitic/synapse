with Ada.Containers.Indefinite_Ordered_Sets;

with Synapse.Pipeline.Inspection;
with Synapse.Pipeline.Win32;

package body Synapse.Pipeline.System_Inspector is

   use Ada.Strings.Unbounded;
   use type System.Address;
   use type Win32.DWORD;
   use type Win32.BOOL;

   --  Every pipe of a run is named by this and the run's id.
   Prefix : constant String := "synapse-pipeline-";

   --  How long a client may take over a step of its request or its answer,
   --  and how often the listener looks up to see whether it was told to stop,
   --  in milliseconds.
   Client_Patience : constant Win32.DWORD := 2000;
   Poll            : constant Win32.DWORD := 100;

   LF : constant Character := Character'Val (10);

   type Transfer is (Done, Closed, Timed_Out, Failed);

   package Id_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   function Image (Item : Win32.DWORD) return String is
      Text : constant String := Win32.DWORD'Image (Item);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   --  Reads into or writes from Buffer, up to Size bytes, as one overlapped
   --  operation on Item that is given Client_Patience to finish. Event is
   --  the event the operation signals. The operation is over, or cancelled,
   --  when this returns.
   procedure Move
     (Item    : Win32.HANDLE;
      Event   : Win32.HANDLE;
      Reading : Boolean;
      Buffer  : System.Address;
      Size    : Win32.DWORD;
      Count   : out Win32.DWORD;
      Result  : out Transfer)
   is
      Overlap : aliased Win32.OVERLAPPED;
      Moved   : aliased Win32.DWORD := 0;
      Issued  : Win32.BOOL;
      Ignored : Win32.BOOL;
      Error   : Win32.DWORD;
   begin
      Count := 0;
      Result := Failed;
      Ignored := Win32.Reset_Event (Event);
      Overlap.Event := Event;
      Issued :=
        (if Reading
         then Win32.Read_File
                (Item, Buffer, Size, Moved'Address, Overlap'Address)
         else Win32.Write_File
                (Item, Buffer, Size, Moved'Address, Overlap'Address));
      if Issued /= 0 then
         Count := Moved;
         Result := Done;
         return;
      end if;
      Error := Win32.Get_Last_Error;
      if Error = Win32.Error_Broken_Pipe then
         Result := Closed;
         return;
      elsif Error /= Win32.Error_Io_Pending then
         return;
      end if;
      if Win32.Wait_For_Single_Object (Event, Client_Patience) =
         Win32.Wait_Object_0
      then
         if Win32.Get_Overlapped_Result
              (Item, Overlap'Address, Moved'Address, 0) /= 0
         then
            Count := Moved;
            Result := Done;
         elsif Win32.Get_Last_Error = Win32.Error_Broken_Pipe then
            Result := Closed;
         end if;
      else
         Ignored := Win32.Cancel_Io_Ex (Item, Overlap'Address);
         Ignored :=
           Win32.Get_Overlapped_Result
             (Item, Overlap'Address, Moved'Address, 1);
         Result := Timed_Out;
      end if;
   end Move;

   --  What Item says up to a line feed, to the end of what it sends or to
   --  Limit and one byte over, which is enough to see it is too long. A
   --  client that stops saying anything is let go.
   procedure Read_Line
     (Item  : Win32.HANDLE;
      Event : Win32.HANDLE;
      Limit : Natural;
      Text  : out Unbounded_String)
   is
      Buffer : aliased String (1 .. 1024);
      Count  : Win32.DWORD;
      Result : Transfer;
   begin
      Text := Null_Unbounded_String;
      loop
         Move
           (Item, Event, True, Buffer'Address, Buffer'Length, Count, Result);
         exit when Result /= Done or else Count = 0;
         for I in 1 .. Natural (Count) loop
            if Buffer (I) = LF then
               return;
            end if;
            Append (Text, Buffer (I));
         end loop;
         exit when Length (Text) > Limit;
      end loop;
   end Read_Line;

   --  Writes all of Text to Item, and says whether it all went.
   function Write_All
     (Item  : Win32.HANDLE;
      Event : Win32.HANDLE;
      Text  : String) return Boolean
   is
      Data   : aliased String := Text;
      From   : Natural := Data'First;
      Count  : Win32.DWORD;
      Result : Transfer;
   begin
      while From <= Data'Last loop
         Move
           (Item, Event, False, Data (From)'Address,
            Win32.DWORD (Data'Last - From + 1), Count, Result);
         if Result /= Done or else Count = 0 then
            return False;
         end if;
         From := From + Natural (Count);
      end loop;
      return True;
   end Write_All;

   overriding
   function Endpoint_For
     (T : System_Transport; Work_Directory, Id : String) return String
   is
      pragma Unreferenced (T, Work_Directory);
   begin
      return "\\.\pipe\" & Prefix & Id;
   end Endpoint_For;

   overriding
   procedure Listen
     (T         : in out System_Transport;
      Endpoint  : String;
      Listening : out Boolean;
      Reason    : out Unbounded_String)
   is
      Pipe : constant Win32.HANDLE :=
        Win32.Create_Named_Pipe
          (Name          => Win32.Wide (Endpoint),
           Open_Mode     =>
             Win32.Pipe_Access_Duplex or Win32.File_Flag_Overlapped,
           Pipe_Mode     => Win32.Pipe_Wait or Win32.Pipe_Reject_Remote,
           Max_Instances => 1,
           Out_Size      => 65_536,
           In_Size       => 65_536,
           Default_Wait  => 0,
           Security      => System.Null_Address);
   begin
      T.Listening := False;
      Listening := False;
      Reason := Null_Unbounded_String;
      if Pipe = Win32.Invalid_Handle then
         Reason :=
           To_Unbounded_String
             ("cannot listen at " & Endpoint & ": error "
              & Image (Win32.Get_Last_Error));
         return;
      end if;
      T.Pipe := Pipe;
      T.Endpoint := To_Unbounded_String (Endpoint);
      T.Listening := True;
      Listening := True;
   end Listen;

   overriding
   procedure Serve
     (T    : in out System_Transport;
      H    : in out Inspector_Transport.Request_Handler'Class;
      Stop : not null access function return Boolean)
   is
      Event   : constant Win32.HANDLE :=
        Win32.Create_Event
          (System.Null_Address, 1, 0, System.Null_Address);
      Ignored : Win32.BOOL;

      --  Answers the client that is connected, and lets it go.
      procedure Serve_Client is
         Request : Unbounded_String;
         Buffer  : aliased String (1 .. 16);
         Count   : Win32.DWORD;
         Result  : Transfer;
      begin
         Read_Line (T.Pipe, Event, Inspection.Max_Request_Bytes, Request);
         declare
            Answer : constant String := H.Respond (To_String (Request));
            Sent   : constant Boolean :=
              Write_All (T.Pipe, Event, Answer & LF);
            pragma Unreferenced (Sent);
         begin
            --  The client closes its end when it has read the answer; what
            --  is not read when the pipe is disconnected is lost.
            Move
              (T.Pipe, Event, True, Buffer'Address, Buffer'Length, Count,
               Result);
         end;
      exception
         when others =>
            null;
      end Serve_Client;

      --  Waits for a client to connect, looking up to see whether it was told
      --  to stop. Ready says whether one has.
      procedure Wait_For_Client (Ready : out Boolean) is
         Overlap : aliased Win32.OVERLAPPED;
         Moved   : aliased Win32.DWORD := 0;
         Error   : Win32.DWORD;
      begin
         Ready := False;
         Ignored := Win32.Reset_Event (Event);
         Overlap.Event := Event;
         if Win32.Connect_Named_Pipe (T.Pipe, Overlap'Address) /= 0 then
            Ready := True;
            return;
         end if;
         Error := Win32.Get_Last_Error;
         if Error = Win32.Error_Pipe_Connected then
            Ready := True;
         elsif Error = Win32.Error_Io_Pending then
            loop
               if Win32.Wait_For_Single_Object (Event, Poll) =
                  Win32.Wait_Object_0
               then
                  Ready := True;
                  exit;
               end if;
               exit when Stop.all;
            end loop;
            if not Ready then
               Ignored := Win32.Cancel_Io_Ex (T.Pipe, Overlap'Address);
               Ready :=
                 Win32.Get_Overlapped_Result
                   (T.Pipe, Overlap'Address, Moved'Address, 1) /= 0;
            end if;
         else
            delay Duration (Poll) / 1000.0;
         end if;
      end Wait_For_Client;

      Ready : Boolean;
   begin
      if not T.Listening or else Event = System.Null_Address then
         return;
      end if;
      while not Stop.all loop
         Wait_For_Client (Ready);
         if Ready then
            Serve_Client;
            Ignored := Win32.Disconnect_Named_Pipe (T.Pipe);
         end if;
      end loop;
      Ignored := Win32.Close_Handle (Event);
   exception
      when others =>
         Ignored := Win32.Close_Handle (Event);
         raise;
   end Serve;

   overriding
   procedure Close (T : in out System_Transport) is
      Ignored : Win32.BOOL;
   begin
      if T.Pipe /= System.Null_Address then
         Ignored := Win32.Disconnect_Named_Pipe (T.Pipe);
         Ignored := Win32.Close_Handle (T.Pipe);
         T.Pipe := System.Null_Address;
      end if;
      T.Listening := False;
   end Close;

   overriding
   function Ids
     (T : System_Transport; Work_Directory : String)
      return Synapse.Core.Text_Lists.Vector
   is
      pragma Unreferenced (T, Work_Directory);
      Result  : Synapse.Core.Text_Lists.Vector;
      Names   : Id_Sets.Set;
      Data    : aliased Win32.WIN32_FIND_DATAW;
      Search  : Win32.HANDLE;
      Ignored : Win32.BOOL;
   begin
      Search :=
        Win32.Find_First_File
          (Win32.Wide ("\\.\pipe\" & Prefix & "*"), Data'Address);
      if Search = Win32.Invalid_Handle then
         return Result;
      end if;
      loop
         declare
            Name : constant String := Win32.Narrow (Data.File_Name);
         begin
            if Name'Length > Prefix'Length
              and then Name (Name'First .. Name'First + Prefix'Length - 1) =
                       Prefix
            then
               Names.Include (Name (Name'First + Prefix'Length .. Name'Last));
            end if;
         end;
         exit when Win32.Find_Next_File (Search, Data'Address) = 0;
      end loop;
      Ignored := Win32.Find_Close (Search);
      for Id of Names loop
         Result.Append (To_Unbounded_String (Id));
      end loop;
      return Result;
   exception
      when others =>
         return Result;
   end Ids;

   overriding
   procedure Ask
     (T         : System_Transport;
      Endpoint  : String;
      Request   : String;
      Answered  : out Boolean;
      Answer    : out Unbounded_String)
   is
      pragma Unreferenced (T);
      Name    : constant Win32.C.wchar_array := Win32.Wide (Endpoint);
      Item    : Win32.HANDLE := Win32.Invalid_Handle;
      Event   : Win32.HANDLE;
      Ignored : Win32.BOOL;
      Reply   : Unbounded_String;
   begin
      Answered := False;
      Answer := Null_Unbounded_String;
      for Attempt in 1 .. 3 loop
         Item :=
           Win32.Create_File
             (Name, Win32.Generic_Read or Win32.Generic_Write, 0,
              System.Null_Address, Win32.Open_Existing,
              Win32.File_Flag_Overlapped, System.Null_Address);
         exit when Item /= Win32.Invalid_Handle;
         exit when Win32.Get_Last_Error /= Win32.Error_Pipe_Busy;
         Ignored := Win32.Wait_Named_Pipe (Name, Client_Patience);
      end loop;
      if Item = Win32.Invalid_Handle then
         Answer :=
           To_Unbounded_String
             ("nothing answers at " & Endpoint & ": error "
              & Image (Win32.Get_Last_Error));
         return;
      end if;
      Event :=
        Win32.Create_Event (System.Null_Address, 1, 0, System.Null_Address);
      if Event /= System.Null_Address
        and then Write_All (Item, Event, Request & LF)
      then
         Read_Line (Item, Event, Inspection.Max_Response_Bytes, Reply);
      end if;
      if Event /= System.Null_Address then
         Ignored := Win32.Close_Handle (Event);
      end if;
      Ignored := Win32.Close_Handle (Item);
      if Length (Reply) = 0 then
         Answer := To_Unbounded_String ("nothing came back from " & Endpoint);
      else
         Answered := True;
         Answer := Reply;
      end if;
   exception
      when others =>
         Answered := False;
         Answer := To_Unbounded_String ("nothing answers at " & Endpoint);
   end Ask;

end Synapse.Pipeline.System_Inspector;
