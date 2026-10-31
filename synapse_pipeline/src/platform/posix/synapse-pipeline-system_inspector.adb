with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;

with GNAT.OS_Lib;

with Interfaces.C;

with Synapse.Pipeline.Inspection;

package body Synapse.Pipeline.System_Inspector is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   use type GNAT.Sockets.Selector_Status;
   use type GNAT.Sockets.Socket_Type;

   LF : constant Character := Character'Val (10);

   --  How long a client may take to say its request, and how often the
   --  listener looks up to see whether it was told to stop.
   Client_Patience : constant Duration := 2.0;
   Poll            : constant Duration := 0.1;

   function C_Chmod
     (Path : Interfaces.C.char_array; Mode : Interfaces.C.unsigned)
      return Interfaces.C.int
   with Import, Convention => C, External_Name => "chmod";

   --  Only the user may read, write or enter Path. Failing to say so is not
   --  reported: the path was just made by this program.
   procedure Keep_Private (Path : String; Mode : Interfaces.C.unsigned) is
      Ignored : constant Interfaces.C.int :=
        C_Chmod (Interfaces.C.To_C (Path), Mode);
   begin
      null;
   end Keep_Private;

   function Directory_Of (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (Path'First .. I - 1);
         end if;
      end loop;
      return "";
   end Directory_Of;

   overriding
   function Endpoint_For
     (T : System_Transport; Work_Directory, Id : String) return String
   is
      pragma Unreferenced (T);
   begin
      return Work_Directory & "/pipelines/" & Id & ".sock";
   end Endpoint_For;

   overriding
   procedure Listen
     (T         : in out System_Transport;
      Endpoint  : String;
      Listening : out Boolean;
      Reason    : out Unbounded_String)
   is
      Directory : constant String := Directory_Of (Endpoint);
   begin
      Listening := False;
      Reason := Null_Unbounded_String;
      if Endpoint'Length > Max_Endpoint_Length then
         Reason :=
           To_Unbounded_String
             ("the path of the socket is too long for a Unix socket ("
              & Natural'Image (Endpoint'Length) & " bytes, at most"
              & Natural'Image (Max_Endpoint_Length) & "): " & Endpoint);
         return;
      end if;
      if Directory /= "" then
         Ada.Directories.Create_Path (Directory);
         Keep_Private (Directory, 8#700#);
      end if;
      GNAT.Sockets.Create_Socket
        (T.Server, GNAT.Sockets.Family_Unix, GNAT.Sockets.Socket_Stream);
      GNAT.Sockets.Bind_Socket
        (T.Server,
         (Family => GNAT.Sockets.Family_Unix,
          Name   => To_Unbounded_String (Endpoint)));
      Keep_Private (Endpoint, 8#600#);
      GNAT.Sockets.Listen_Socket (T.Server, 8);
      T.Endpoint := To_Unbounded_String (Endpoint);
      T.Listening := True;
      Listening := True;
   exception
      when E : others =>
         if T.Server /= GNAT.Sockets.No_Socket then
            begin
               GNAT.Sockets.Close_Socket (T.Server);
            exception
               when others =>
                  null;
            end;
            T.Server := GNAT.Sockets.No_Socket;
         end if;
         T.Listening := False;
         Listening := False;
         Reason :=
           To_Unbounded_String
             ("cannot listen at " & Endpoint & ": "
              & Ada.Exceptions.Exception_Message (E));
   end Listen;

   --  The request a client sends: what it says up to a line feed or to the
   --  end of what it sends, and no more than the limit and one byte over,
   --  which is enough for the handler to see it is too long.
   function Read_Request (Client : GNAT.Sockets.Socket_Type) return String is
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 1024);
      Last    : Ada.Streams.Stream_Element_Offset;
      Request : Unbounded_String;
   begin
      GNAT.Sockets.Set_Socket_Option
        (Client, GNAT.Sockets.Socket_Level,
         (GNAT.Sockets.Receive_Timeout, Client_Patience));
      loop
         GNAT.Sockets.Receive_Socket (Client, Buffer, Last);
         exit when Last < Buffer'First;
         for I in Buffer'First .. Last loop
            if Character'Val (Buffer (I)) = LF then
               return To_String (Request);
            end if;
            Append (Request, Character'Val (Buffer (I)));
         end loop;
         exit when Length (Request) > Inspection.Max_Request_Bytes;
      end loop;
      return To_String (Request);
   end Read_Request;

   procedure Send_All (Client : GNAT.Sockets.Socket_Type; Text : String) is
      Bytes : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
      From  : Ada.Streams.Stream_Element_Offset := Bytes'First;
      Last  : Ada.Streams.Stream_Element_Offset;
   begin
      for I in Text'Range loop
         Bytes (Ada.Streams.Stream_Element_Offset (I - Text'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (I)));
      end loop;
      while From <= Bytes'Last loop
         GNAT.Sockets.Send_Socket
           (Client, Bytes (From .. Bytes'Last), Last);
         exit when Last < From;
         From := Last + 1;
      end loop;
   end Send_All;

   overriding
   procedure Serve
     (T    : in out System_Transport;
      H    : in out Inspector_Transport.Request_Handler'Class;
      Stop : not null access function return Boolean)
   is
      Selector : GNAT.Sockets.Selector_Type;
      Ready    : GNAT.Sockets.Socket_Set_Type;
      Nothing  : GNAT.Sockets.Socket_Set_Type;
      Status   : GNAT.Sockets.Selector_Status;
      Client   : GNAT.Sockets.Socket_Type;
      Address  : GNAT.Sockets.Sock_Addr_Type;
   begin
      if not T.Listening then
         return;
      end if;
      GNAT.Sockets.Create_Selector (Selector);
      while not Stop.all loop
         GNAT.Sockets.Empty (Ready);
         GNAT.Sockets.Empty (Nothing);
         GNAT.Sockets.Set (Ready, T.Server);
         GNAT.Sockets.Check_Selector
           (Selector, Ready, Nothing, Status, Timeout => Poll);
         if Status = GNAT.Sockets.Completed
           and then not GNAT.Sockets.Is_Empty (Ready)
         then
            begin
               GNAT.Sockets.Accept_Socket (T.Server, Client, Address);
               begin
                  declare
                     Answer : constant String :=
                       H.Respond (Read_Request (Client));
                  begin
                     Send_All (Client, Answer & LF);
                  end;
               exception
                  when others =>
                     null;
               end;
               GNAT.Sockets.Close_Socket (Client);
            exception
               when others =>
                  null;
            end;
         end if;
         GNAT.Sockets.Empty (Ready);
      end loop;
      GNAT.Sockets.Close_Selector (Selector);
   exception
      when others =>
         begin
            GNAT.Sockets.Close_Selector (Selector);
         exception
            when others =>
               null;
         end;
         raise;
   end Serve;

   overriding
   function Ids
     (T : System_Transport; Work_Directory : String)
      return Synapse.Core.Text_Lists.Vector
   is
      pragma Unreferenced (T);
      Directory : constant String := Work_Directory & "/pipelines";
      Names     : Synapse.Core.Text_Lists.Sets.Set;
      Result    : Synapse.Core.Text_Lists.Vector;
      Search    : Ada.Directories.Search_Type;
      Item      : Ada.Directories.Directory_Entry_Type;
   begin
      if Work_Directory = "" or else not Ada.Directories.Exists (Directory)
      then
         return Result;
      end if;
      Ada.Directories.Start_Search
        (Search, Directory, "",
         [Ada.Directories.Directory => False, others => True]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name'Length > 5
              and then Name (Name'Last - 4 .. Name'Last) = ".sock"
            then
               Names.Include (Name (Name'First .. Name'Last - 5));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
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
      Sock   : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 4096);
      Last   : Ada.Streams.Stream_Element_Offset;
      Reply  : Unbounded_String;
   begin
      Answered := False;
      Answer := Null_Unbounded_String;
      GNAT.Sockets.Create_Socket
        (Sock, GNAT.Sockets.Family_Unix, GNAT.Sockets.Socket_Stream);
      GNAT.Sockets.Set_Socket_Option
        (Sock, GNAT.Sockets.Socket_Level,
         (GNAT.Sockets.Receive_Timeout, Client_Patience));
      GNAT.Sockets.Connect_Socket
        (Sock,
         (Family => GNAT.Sockets.Family_Unix,
          Name   => To_Unbounded_String (Endpoint)));
      Send_All (Sock, Request & LF);
      loop
         GNAT.Sockets.Receive_Socket (Sock, Buffer, Last);
         exit when Last < Buffer'First;
         for I in Buffer'First .. Last loop
            if Character'Val (Buffer (I)) /= LF then
               Append (Reply, Character'Val (Buffer (I)));
            end if;
         end loop;
      end loop;
      GNAT.Sockets.Close_Socket (Sock);
      if Length (Reply) = 0 then
         Answer := To_Unbounded_String ("nothing came back from " & Endpoint);
      else
         Answered := True;
         Answer := Reply;
      end if;
   exception
      when E : others =>
         if Sock /= GNAT.Sockets.No_Socket then
            begin
               GNAT.Sockets.Close_Socket (Sock);
            exception
               when others =>
                  null;
            end;
         end if;
         Answered := False;
         Answer :=
           To_Unbounded_String
             ("nothing answers at " & Endpoint & ": "
              & Ada.Exceptions.Exception_Message (E));
   end Ask;

   overriding
   procedure Close (T : in out System_Transport) is
      Removed : Boolean;
   begin
      if T.Server /= GNAT.Sockets.No_Socket then
         begin
            GNAT.Sockets.Close_Socket (T.Server);
         exception
            when others =>
               null;
         end;
         T.Server := GNAT.Sockets.No_Socket;
      end if;
      if T.Listening and then Length (T.Endpoint) > 0 then
         --  Not Ada.Directories.Delete_File, which will not remove a socket.
         GNAT.OS_Lib.Delete_File (To_String (T.Endpoint), Removed);
      end if;
      T.Listening := False;
   end Close;

end Synapse.Pipeline.System_Inspector;
