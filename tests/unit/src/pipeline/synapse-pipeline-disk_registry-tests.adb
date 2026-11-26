with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with GNAT.OS_Lib;
with GNAT.Sockets;

with Synapse.Pipeline.Registry_Contract;
with Synapse.Test_Scratch;

package body Synapse.Pipeline.Disk_Registry.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Text_Of (Item : Registry_Store.Maybe_Content) return String is
     (if Item.Found then To_String (Item.Value) else "<none>");

   --  Exactly the bytes of Content: Text_IO would add a line terminator.
   procedure Write (Path, Content : String) is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Path);
      String'Write (Ada.Streams.Stream_IO.Stream (File), Content);
      Ada.Streams.Stream_IO.Close (File);
   end Write;

   --  What `ls -ld` says about Path, such as `drwx------`, or "" where there
   --  is no such program.
   function Mode_Of (Path : String; Scratch : String) return String is
      Output  : constant String := Scratch & "/mode.txt";
      Success : Boolean;
      Code    : Integer;
      Args    : GNAT.OS_Lib.Argument_List :=
        [new String'("-ld"), new String'(Path)];
   begin
      GNAT.OS_Lib.Spawn
        ("/bin/ls", Args, Output, Success, Code, Err_To_Out => True);
      for Item of Args loop
         GNAT.OS_Lib.Free (Item);
      end loop;
      if not Success or else Code /= 0 then
         return "";
      end if;
      declare
         File : Ada.Streams.Stream_IO.File_Type;
         Text : String (1 .. 10) := [others => ' '];
         Last : Ada.Streams.Stream_Element_Offset;
         Data : Ada.Streams.Stream_Element_Array (1 .. 10);
      begin
         Ada.Streams.Stream_IO.Open
           (File, Ada.Streams.Stream_IO.In_File, Output);
         Ada.Streams.Stream_IO.Read (File, Data, Last);
         Ada.Streams.Stream_IO.Close (File);
         for I in 1 .. Natural (Last) loop
            Text (I) :=
              Character'Val
                (Data (Ada.Streams.Stream_Element_Offset (I)));
         end loop;
         return Text;
      end;
   end Mode_Of;

   procedure It_Meets_The_Contract (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      R : Disk_Registry;
   begin
      R.Open (Synapse.Test_Scratch.Path (Scratch, "work"));
      Registry_Contract.Check (R, "exec-x");
   end It_Meets_The_Contract;

   procedure A_Summary_Is_Replaced_Without_Leaving_A_Temporary_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      R   : Disk_Registry;
      Dir : constant String :=
        Synapse.Test_Scratch.Path (Scratch, "work") & "/pipelines/exec-1";
   begin
      R.Open (Synapse.Test_Scratch.Path (Scratch, "work"));
      Assert (R.Create ("exec-1") = Registry_Store.Created, "made");
      Assert (R.Replace_Summary ("exec-1", "first"), "written");
      Assert (R.Replace_Summary ("exec-1", "second"), "replaced");
      Assert
        (Text_Of (R.Read_Summary ("exec-1")) = "second"
         and then not Ada.Directories.Exists (Dir & "/execution.json.tmp"),
         "the summary is whole and nothing is left beside it");
      Assert
        (Natural (R.Ids.Length) = 1, "the execution is the only one listed");
   end A_Summary_Is_Replaced_Without_Leaving_A_Temporary_File;

   procedure The_Name_File_Holds_The_Name_With_No_Line_Break
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      R    : Disk_Registry;
      Path : constant String :=
        Synapse.Test_Scratch.Path (Scratch, "work")
        & "/pipelines/exec-1/name";
   begin
      R.Open (Synapse.Test_Scratch.Path (Scratch, "work"));
      Assert (R.Create ("exec-1") = Registry_Store.Created, "made");
      Assert
        (not Ada.Directories.Exists (Path), "a run with no name has no file");
      Assert (R.Replace_Name ("exec-1", "Fix login"), "written");
      Assert
        (Natural (Ada.Directories.Size (Path)) = 9,
         "the file holds the name and nothing more");
      Assert
        (Text_Of (R.Read_Name ("exec-1")) = "Fix login"
         and then not Ada.Directories.Exists (Path & ".tmp"),
         "and nothing is left beside it");
      Assert (R.Replace_Name ("exec-1", ""), "cleared");
      Assert (not Ada.Directories.Exists (Path), "and the file is gone");
   end The_Name_File_Holds_The_Name_With_No_Line_Break;

   --  A run whose program was killed leaves its socket file behind, which
   --  Ada.Directories cannot delete.
   procedure A_Record_Holding_A_Leftover_Socket_File_Is_Removed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      R : Disk_Registry;
   begin
      if GNAT.OS_Lib.Directory_Separator /= '/' then
         Synapse.Test_Scratch.Remove (Scratch);
         return;
      end if;
      R.Open (Synapse.Test_Scratch.Path (Scratch));
      Assert (R.Create ("exec-1") = Registry_Store.Created, "made");
      Assert (R.Replace_Summary ("exec-1", "{}"), "written");
      Assert
        (R.Write_Transcript ("exec-1", "step.jsonl", "text"),
         "a transcript in a folder of its own");
      declare
         Sock : GNAT.Sockets.Socket_Type;
         Path : constant String :=
           R.Directory_Of ("exec-1") & "/execution.sock";
      begin
         GNAT.Sockets.Create_Socket (Sock, GNAT.Sockets.Family_Unix);
         GNAT.Sockets.Bind_Socket
           (Sock, GNAT.Sockets.Unix_Socket_Address (Path));
         GNAT.Sockets.Close_Socket (Sock);
         Assert
           (Ada.Directories.Exists (Path)
            and then not GNAT.OS_Lib.Is_Regular_File (Path),
            "the socket file is left behind");
      end;
      Assert (R.Remove ("exec-1"), "removed");
      Assert
        (not Ada.Directories.Exists (R.Directory_Of ("exec-1"))
         and then R.Ids.Is_Empty,
         "and nothing of it is left");
      Synapse.Test_Scratch.Remove (Scratch);
   end A_Record_Holding_A_Leftover_Socket_File_Is_Removed;

   procedure Only_The_User_Can_Enter_An_Execution
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      R : Disk_Registry;
   begin
      Ada.Directories.Create_Path (Synapse.Test_Scratch.Path (Scratch, "m"));
      R.Open (Synapse.Test_Scratch.Path (Scratch, "work"));
      Assert (R.Create ("exec-1") = Registry_Store.Created, "made");
      if GNAT.OS_Lib.Directory_Separator = '/' then
         declare
            Mode : constant String :=
              Mode_Of
                (R.Directory_Of ("exec-1"),
                 Synapse.Test_Scratch.Path (Scratch, "m"));
         begin
            Assert
              (Mode'Length >= 10
               and then Ada.Strings.Fixed.Index (Mode, "drwx------") = 1,
               "the directory is the user's alone: " & Mode);
         end;
      end if;
   end Only_The_User_Can_Enter_An_Execution;

   procedure A_Name_Cannot_Leave_The_Registry (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      R : Disk_Registry;
   begin
      R.Open (Synapse.Test_Scratch.Path (Scratch, "work"));
      Assert (R.Create ("exec-1") = Registry_Store.Created, "made");
      Assert
        (R.Create ("../escape") = Registry_Store.Failed
         and then R.Create ("a/b") = Registry_Store.Failed
         and then R.Create ("") = Registry_Store.Failed
         and then R.Create (".hidden") = Registry_Store.Failed,
         "an id with a path in it is refused");
      Assert
        (not R.Write_Transcript ("exec-1", "../x", "text")
         and then not R.Write_Transcript ("exec-1", "", "text"),
         "so is a transcript name with one");
      Assert
        (not Ada.Directories.Exists
           (Synapse.Test_Scratch.Path (Scratch, "work") & "/escape"),
         "and nothing was made outside");
   end A_Name_Cannot_Leave_The_Registry;

   procedure A_Directory_Not_Made_By_The_Registry_Is_Found_Taken
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      R : Disk_Registry;
   begin
      R.Open (Synapse.Test_Scratch.Path (Scratch, "work"));
      Ada.Directories.Create_Path
        (Synapse.Test_Scratch.Path (Scratch, "work") & "/pipelines/exec-9");
      Assert
        (R.Create ("exec-9") = Registry_Store.Already_Exists,
         "a directory that is there is taken");
      Write
        (Synapse.Test_Scratch.Path (Scratch, "work") & "/pipelines/file", "x");
      Assert
        (R.Create ("file") = Registry_Store.Already_Exists,
         "so is a file of that name");
   end A_Directory_Not_Made_By_The_Registry_Is_Found_Taken;

   procedure A_Registry_That_Cannot_Be_Made_Fails_Quietly
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      R : Disk_Registry;
   begin
      --  The work directory is a file, so nothing can be made under it.
      Write (Synapse.Test_Scratch.Path (Scratch, "work"), "a file");
      R.Open (Synapse.Test_Scratch.Path (Scratch, "work"));
      Assert
        (R.Create ("exec-1") = Registry_Store.Failed,
         "a create that cannot be done fails");
      Assert
        (R.Ids.Is_Empty and then not R.Read_Summary ("exec-1").Found,
         "and a registry with nothing in it is empty");
   end A_Registry_That_Cannot_Be_Made_Fails_Quietly;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Disk_Registry");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, It_Meets_The_Contract'Access, "It meets the registry contract");
      Register_Routine
        (T, A_Summary_Is_Replaced_Without_Leaving_A_Temporary_File'Access,
         "A summary is replaced without leaving a temporary file");
      Register_Routine
        (T, The_Name_File_Holds_The_Name_With_No_Line_Break'Access,
         "The name file holds the name with no line break");
      Register_Routine
        (T, A_Record_Holding_A_Leftover_Socket_File_Is_Removed'Access,
         "A record holding a leftover socket file is removed");
      Register_Routine
        (T, Only_The_User_Can_Enter_An_Execution'Access,
         "Only the user can enter an execution");
      Register_Routine
        (T, A_Name_Cannot_Leave_The_Registry'Access,
         "A name cannot leave the registry");
      Register_Routine
        (T, A_Directory_Not_Made_By_The_Registry_Is_Found_Taken'Access,
         "A directory not made by the registry is found taken");
      Register_Routine
        (T, A_Registry_That_Cannot_Be_Made_Fails_Quietly'Access,
         "A registry that cannot be made fails quietly");
   end Register_Tests;

end Synapse.Pipeline.Disk_Registry.Tests;
