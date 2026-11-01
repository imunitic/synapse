with Ada.Directories;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with AUnit.Assertions;

with GNAT.OS_Lib;
with GNAT.Sockets;

with Synapse.Core.JSON;
with Synapse.Pipeline.Contexts;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Inspection;
with Synapse.Pipeline.Inspectors;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.States;
with Synapse.Test_Scratch;

package body Synapse.Pipeline.System_Inspector.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   --  Sockets here are Unix domain sockets; Windows has the stub.
   function On_Windows return Boolean is
     (GNAT.OS_Lib.Directory_Separator = '\');

   function Initial_State return States.State is
      Pipeline : Resolved.Pipeline;
   begin
      Pipeline.Name := To_Unbounded_String ("P");
      Pipeline.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("A"), Harness => Harnesses.Claude,
            others => <>));
      return States.Initial (Pipeline, JSON.Null_Value);
   end Initial_State;

   --  Connects to the socket at Path, sends Request, and says what comes back
   --  up to a line feed or the end of what the server sends.
   function Ask
     (Path : String; Request : String; Newline : Boolean := True;
      Close_Writing : Boolean := False) return String
   is
      Sock   : GNAT.Sockets.Socket_Type;
      Bytes  : Ada.Streams.Stream_Element_Array (1 .. Request'Length + 1);
      Count  : Ada.Streams.Stream_Element_Offset := Request'Length;
      Last   : Ada.Streams.Stream_Element_Offset;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 1024);
      Reply  : Unbounded_String;
   begin
      GNAT.Sockets.Create_Socket
        (Sock, GNAT.Sockets.Family_Unix, GNAT.Sockets.Socket_Stream);
      GNAT.Sockets.Connect_Socket
        (Sock,
         (Family => GNAT.Sockets.Family_Unix,
          Name   => To_Unbounded_String (Path)));
      GNAT.Sockets.Set_Socket_Option
        (Sock, GNAT.Sockets.Socket_Level,
         (GNAT.Sockets.Receive_Timeout, 6.0));
      for I in Request'Range loop
         Bytes (Ada.Streams.Stream_Element_Offset (I - Request'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Request (I)));
      end loop;
      if Newline then
         Count := Count + 1;
         Bytes (Count) := Ada.Streams.Stream_Element (Character'Pos (LF));
      end if;
      GNAT.Sockets.Send_Socket (Sock, Bytes (1 .. Count), Last);
      if Close_Writing then
         GNAT.Sockets.Shutdown_Socket (Sock, GNAT.Sockets.Shut_Write);
      end if;
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
      return To_String (Reply);
   end Ask;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure A_Path_Too_Long_For_A_Socket_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Transport : System_Transport;
      Listening : Boolean := True;
      Reason    : Unbounded_String;
   begin
      Transport.Listen
        ("/tmp/" & [1 .. Max_Endpoint_Length => 'x'] & ".sock", Listening,
         Reason);
      Assert (not Listening, "refused");
      Assert
        (Has (To_String (Reason), "too long for a Unix socket")
         or else On_Windows,
         "and says why: " & To_String (Reason));
      Transport.Close;
   end A_Path_Too_Long_For_A_Socket_Is_Refused;

   procedure The_Endpoint_Is_In_The_Pipelines_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Transport : System_Transport;
   begin
      if not On_Windows then
         Assert
           (Transport.Endpoint_For ("/w", "exec-1") =
            "/w/pipelines/exec-1.sock",
            "work directory, pipelines, the id");
      end if;
   end The_Endpoint_Is_In_The_Pipelines_Directory;

   procedure A_Client_Over_A_Real_Socket_Is_Answered
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch   : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      Transport : System_Transport;
      Context   : aliased Contexts.Execution_Context;
      Listening : Boolean := False;
      Reason    : Unbounded_String;
      Endpoint  : constant String :=
        Transport.Endpoint_For (Synapse.Test_Scratch.Path (Scratch), "exec-1");
      Replies   : array (1 .. 6) of Unbounded_String;

      procedure Action (Is_Listening : Boolean; Why : String) is
         Moved : States.State := Initial_State;
      begin
         Listening := Is_Listening;
         Reason := To_Unbounded_String (Why);
         Context.Start
           ("exec-1", Synapse.Core.JSON.Null_Value, Initial_State);
         Moved.Steps_Run := 4;
         Context.Publish (Moved);
         Context.Record_Event ("step.finished", "A", JSON.Null_Value);
         Replies (1) :=
           To_Unbounded_String (Ask (Endpoint, "{""command"":""info""}"));
         Replies (2) :=
           To_Unbounded_String
             (Ask (Endpoint, "{""command"":""events""}", Newline => False,
                   Close_Writing => True));
         Replies (3) :=
           To_Unbounded_String
             (Ask
                (Endpoint,
                 "{""command"":""query"",""expression"":"
                 & "{""var"":""steps_run""}}"));
         Replies (4) := To_Unbounded_String (Ask (Endpoint, "not json"));
         Replies (5) :=
           To_Unbounded_String
             (Ask
                (Endpoint,
                 "{""command"":""info"",""pad"":"""
                 & [1 .. Inspection.Max_Request_Bytes + 100 => 'x'] & """}"));
         Replies (6) :=
           To_Unbounded_String (Ask (Endpoint, "{""command"":""execute""}"));
      end Action;
   begin
      if On_Windows then
         Synapse.Test_Scratch.Remove (Scratch);
         return;
      end if;
      Inspectors.Serve_While (Transport, Endpoint, Context, Action'Access);
      Assert (Listening, "it listened: " & To_String (Reason));
      Assert
        (Has (To_String (Replies (1)), """ok"":true")
         and then Has (To_String (Replies (1)), """steps_run"":4")
         and then Has (To_String (Replies (1)), """execution_id"":""exec-1"""),
         "info over the socket: " & To_String (Replies (1)));
      Assert
        (Has (To_String (Replies (2)), """kind"":""step.finished"""),
         "a request with no newline, the client done writing: "
         & To_String (Replies (2)));
      Assert
        (Has (To_String (Replies (3)), """result"":4"),
         "a query: " & To_String (Replies (3)));
      Assert
        (Has (To_String (Replies (4)), "the request is not JSON"),
         "garbage is refused: " & To_String (Replies (4)));
      Assert
        (Has (To_String (Replies (5)), "the request is larger than"),
         "and so is too much: " & To_String (Replies (5)));
      Assert
        (Has (To_String (Replies (6)), "'execute' is not a command"),
         "and so is a command that would change the run");
      Assert
        (not Ada.Directories.Exists (Endpoint),
         "the socket file is gone once serving is done");
      Synapse.Test_Scratch.Remove (Scratch);
   end A_Client_Over_A_Real_Socket_Is_Answered;

   procedure A_Silent_Client_Does_Not_Block_The_Next
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch   : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      Transport : System_Transport;
      Context   : aliased Contexts.Execution_Context;
      Endpoint  : constant String :=
        Transport.Endpoint_For (Synapse.Test_Scratch.Path (Scratch), "exec-2");
      Reply     : Unbounded_String;

      procedure Action (Listening : Boolean; Reason : String) is
         pragma Unreferenced (Reason);
         Silent : GNAT.Sockets.Socket_Type;
      begin
         Assert (Listening, "it listens");
         Context.Start
           ("exec-2", Synapse.Core.JSON.Null_Value, Initial_State);
         GNAT.Sockets.Create_Socket
           (Silent, GNAT.Sockets.Family_Unix, GNAT.Sockets.Socket_Stream);
         GNAT.Sockets.Connect_Socket
           (Silent,
            (Family => GNAT.Sockets.Family_Unix,
             Name   => To_Unbounded_String (Endpoint)));
         Reply :=
           To_Unbounded_String (Ask (Endpoint, "{""command"":""info""}"));
         GNAT.Sockets.Close_Socket (Silent);
      end Action;
   begin
      if On_Windows then
         Synapse.Test_Scratch.Remove (Scratch);
         return;
      end if;
      Inspectors.Serve_While (Transport, Endpoint, Context, Action'Access);
      Assert
        (Has (To_String (Reply), """ok"":true"),
         "a client that connects and says nothing is let go, and the next is "
         & "answered: " & To_String (Reply));
      Synapse.Test_Scratch.Remove (Scratch);
   end A_Silent_Client_Does_Not_Block_The_Next;

   procedure The_Directory_Is_Private (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Scratch   : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      Transport : System_Transport;
      Listening : Boolean;
      Reason    : Unbounded_String;
      Endpoint  : constant String :=
        Transport.Endpoint_For (Synapse.Test_Scratch.Path (Scratch), "exec-3");
      Listing   : constant String :=
        Synapse.Test_Scratch.Path (Scratch, "listing.txt");
      Args      : GNAT.OS_Lib.Argument_List (1 .. 2) :=
        [new String'("-ld"),
         new String'(Synapse.Test_Scratch.Path (Scratch, "pipelines"))];
      Done      : Boolean;
      Code      : Integer;
   begin
      if On_Windows then
         Synapse.Test_Scratch.Remove (Scratch);
         return;
      end if;
      Transport.Listen (Endpoint, Listening, Reason);
      Assert (Listening, "it listened: " & To_String (Reason));
      GNAT.OS_Lib.Spawn ("/bin/ls", Args, Listing, Done, Code);
      Transport.Close;
      GNAT.OS_Lib.Free (Args (1));
      GNAT.OS_Lib.Free (Args (2));
      declare
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Listing);
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            Ada.Text_IO.Close (File);
            Assert
              (Done and then Line'Length >= 10
               and then Line (Line'First .. Line'First + 9) = "drwx------",
               "only the user may enter it: " & Line);
         end;
      end;
      Synapse.Test_Scratch.Remove (Scratch);
   end The_Directory_Is_Private;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.System_Inspector");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Path_Too_Long_For_A_Socket_Is_Refused'Access,
         "A path too long for a socket is refused");
      Register_Routine
        (T, The_Endpoint_Is_In_The_Pipelines_Directory'Access,
         "The endpoint is in the pipelines directory");
      Register_Routine
        (T, A_Client_Over_A_Real_Socket_Is_Answered'Access,
         "A client over a real socket is answered");
      Register_Routine
        (T, A_Silent_Client_Does_Not_Block_The_Next'Access,
         "A silent client does not block the next");
      Register_Routine
        (T, The_Directory_Is_Private'Access, "The directory is private");
   end Register_Tests;

end Synapse.Pipeline.System_Inspector.Tests;
