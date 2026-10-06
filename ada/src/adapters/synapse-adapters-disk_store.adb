with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;

with Synapse.Adapters.Replace_File;
with Synapse.Core.Frontmatter;
with Synapse.Core.Node_Path;
with Synapse.Core.Text_Search;

package body Synapse.Adapters.Disk_Store is

   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Kind;
   use type Ada.Streams.Stream_IO.Count;

   Largest_Read : constant := 256 * 1024 * 1024;

   function Create (Vault, Namespace : String) return Disk_Store is
   begin
      return
        (Port.Store with
           Vault     => To_Unbounded_String (Vault),
           Namespace => To_Unbounded_String (Namespace));
   end Create;

   --  The directory a store's nodes live under.
   function Root (S : Disk_Store) return String
   is (if S.Namespace = Null_Unbounded_String
       then To_String (S.Vault)
       else To_String (S.Vault) & "/" & To_String (S.Namespace));

   function Path_Of (S : Disk_Store; Node : String) return String is
   begin
      if not Core.Node_Path.Is_Safe (Node) then
         raise Port.Unsafe_Node with Node;
      end if;
      return Root (S) & "/" & Node;
   end Path_Of;

   function Failure
     (Action, Path : String; E : Ada.Exceptions.Exception_Occurrence)
      return String
   is (Action & " " & Path & ": " & Ada.Exceptions.Exception_Name (E)
       & (if Ada.Exceptions.Exception_Message (E)'Length > 0
          then " (" & Ada.Exceptions.Exception_Message (E) & ")" else ""));

   function Read_File (Path : String) return String is
      package IO renames Ada.Streams.Stream_IO;
      File : IO.File_Type;
   begin
      IO.Open (File, IO.In_File, Path);
      declare
         Length : constant IO.Count := IO.Size (File);
      begin
         if Length > IO.Count (Largest_Read) then
            IO.Close (File);
            raise Port.Store_Failure with "file too large: " & Path;
         end if;
         declare
            use type Ada.Streams.Stream_Element_Offset;
            Data : Ada.Streams.Stream_Element_Array
                     (1 .. Ada.Streams.Stream_Element_Offset (Length));
            Last : Ada.Streams.Stream_Element_Offset;
            Text : String (1 .. Natural (Length));
         begin
            IO.Read (File, Data, Last);
            IO.Close (File);
            if Last /= Data'Last then
               raise Port.Store_Failure with "short read: " & Path;
            end if;
            for I in Text'Range loop
               Text (I) :=
                 Character'Val (Data (Ada.Streams.Stream_Element_Offset (I)));
            end loop;
            return Text;
         end;
      end;
   exception
      when Port.Store_Failure =>
         raise;
      when E : others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         raise Port.Store_Failure with Failure ("cannot read", Path, E);
   end Read_File;

   overriding
   function Read (S : in out Disk_Store; Node : String) return Port.Maybe_Text
   is
      Path : constant String := Path_Of (S, Node);
   begin
      if not Ada.Directories.Exists (Path) then
         return (Found => False);
      end if;
      if Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File then
         raise Port.Store_Failure with "not a file: " & Path;
      end if;
      return (Found => True, Text => To_Unbounded_String (Read_File (Path)));
   exception
      when Ada.IO_Exceptions.Name_Error =>
         return (Found => False);
      when Port.Store_Failure | Port.Unsafe_Node =>
         raise;
      when E : others =>
         raise Port.Store_Failure with Failure ("cannot read", Path, E);
   end Read;

   procedure Write_File (Path, Content : String) is
      package IO renames Ada.Streams.Stream_IO;
      use type Ada.Streams.Stream_Element_Offset;
      File : IO.File_Type;
      Data : Ada.Streams.Stream_Element_Array
               (1 .. Ada.Streams.Stream_Element_Offset (Content'Length));
   begin
      for I in Data'Range loop
         Data (I) :=
           Ada.Streams.Stream_Element
             (Character'Pos (Content (Content'First + Natural (I) - 1)));
      end loop;
      IO.Create (File, IO.Out_File, Path);
      IO.Write (File, Data);
      IO.Close (File);
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         raise;
   end Write_File;

   overriding
   function Write
     (S : in out Disk_Store; Node, Content : String) return Port.Write_Result
   is
      Path : constant String := Path_Of (S, Node);
      Temp : constant String := Path & ".tmp";
   begin
      declare
         Slash : Natural := 0;
      begin
         for I in reverse Path'Range loop
            if Path (I) = '/' then
               Slash := I;
               exit;
            end if;
         end loop;
         if Slash > Path'First then
            Ada.Directories.Create_Path (Path (Path'First .. Slash - 1));
         end if;
      end;

      begin
         Write_File (Temp, Content);
         Replace_File.Replace (Temp, Path);
      exception
         when others =>
            begin
               if Ada.Directories.Exists (Temp) then
                  Ada.Directories.Delete_File (Temp);
               end if;
            exception
               when others =>
                  null;
            end;
            raise;
      end;
      return (others => <>);
   exception
      when Port.Store_Failure | Port.Unsafe_Node =>
         raise;
      when E : others =>
         raise Port.Store_Failure with Failure ("cannot write", Path, E);
   end Write;

   --  Appends to Names every Markdown file under Directory, as a path
   --  relative to Base.
   procedure Scan
     (Dir, Base : String; Names : in out Core.Text_Lists.Vector)
   is
      use Ada.Directories;
      package Directories renames Ada.Directories;
      Search : Search_Type;
      Item   : Directory_Entry_Type;
   begin
      Start_Search
        (Search, Dir, "",
         [Ordinary_File => True, Directory => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         declare
            Simple : constant String := Simple_Name (Item);
            Child  : constant String :=
              (if Base'Length = 0 then Simple else Base & "/" & Simple);
         begin
            if Simple (Simple'First) /= '.' then
               if Kind (Item) = Directories.Directory then
                  Scan (Full_Name (Item), Child, Names);
               elsif Simple'Length > 3
                 and then Simple (Simple'Last - 2 .. Simple'Last) = ".md"
               then
                  Names.Append (To_Unbounded_String (Child));
               elsif Simple = ".md" then
                  null;
               end if;
            end if;
         end;
      end loop;
      End_Search (Search);
   end Scan;

   package Sorting is new Core.Text_Lists.Vectors.Generic_Sorting;

   overriding
   function List (S : in out Disk_Store) return Core.Text_Lists.Vector is
      Result : Core.Text_Lists.Vector;
      Dir    : constant String := Root (S);
   begin
      if not Ada.Directories.Exists (Dir)
        or else Ada.Directories.Kind (Dir) /= Ada.Directories.Directory
      then
         return Result;
      end if;
      Scan (Dir, "", Result);
      Sorting.Sort (Result);
      return Result;
   exception
      when E : others =>
         raise Port.Store_Failure with Failure ("cannot list", Dir, E);
   end List;

   function Better (A, B : Port.Hit) return Boolean
   is (A.Score > B.Score
       or else (A.Score = B.Score and then A.Node < B.Node));

   package Hit_Sorting is new Port.Hit_Vectors.Generic_Sorting (Better);

   overriding
   function Search
     (S : in out Disk_Store; Query : String) return Port.Hit_Vectors.Vector
   is
      Result : Port.Hit_Vectors.Vector;
   begin
      for Name of List (S) loop
         declare
            Node  : constant String := To_String (Name);
            Found : constant Port.Maybe_Text := Read (S, Node);
         begin
            if Found.Found then
               declare
                  Text  : constant String := To_String (Found.Text);
                  Span  : constant Core.Frontmatter.Span :=
                    Core.Frontmatter.Body_After (Text);
                  Prose : constant String :=
                    Text (Text'First + Span.First
                          .. Text'First + Span.Stop - 1);
                  Count : constant Natural :=
                    Core.Text_Search.Count_Ignore_Case (Prose, Query);
                  Line  : constant Core.Text_Search.Maybe_Line :=
                    Core.Text_Search.First_Matching_Line (Prose, Query);
               begin
                  if Count > 0 then
                     Result.Append
                       (Port.Hit'
                          (Node    => Name,
                           Score   => Float (Count),
                           Context =>
                             (if Line.Found
                              then To_Unbounded_String
                                     (Prose (Line.First .. Line.Last))
                              else Null_Unbounded_String)));
                  end if;
               end;
            end if;
         end;
      end loop;
      Hit_Sorting.Sort (Result);
      return Result;
   end Search;

end Synapse.Adapters.Disk_Store;
