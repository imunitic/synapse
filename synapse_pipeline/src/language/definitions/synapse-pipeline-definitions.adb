with Ada.Strings.Unbounded;

with Synapse.Pipeline.Parser;
with Synapse.Pipeline.Syntax;

package body Synapse.Pipeline.Definitions is

   use Ada.Strings.Unbounded;

   function Warning (Problem : Source_Errors.Source_Error) return String is
     ("warning: " & Source_Errors.Image (Problem));

   function Join (Directory, Name : String) return String is
     (if Directory'Length > 0 and then Directory (Directory'Last) = '/'
      then Directory & Name
      else Directory & "/" & Name);

   function Load
     (Files : File_System.File_System'Class;
      Roots : Search_Paths.Root_Vectors.Vector) return Load_Report
   is
      Report : Load_Report;

      procedure Problem (Error : Source_Errors.Source_Error) is
      begin
         Report.Problems.Append (Error);
      end Problem;

      --  Marks Name failed because of Error, which is also a problem.
      procedure Fail (Name : String; Error : Source_Errors.Source_Error) is
      begin
         Namespaces.Fail (Report.Definitions, Name, Error);
         Problem (Error);
      end Fail;

      function Error_In
        (File, Message : String; Line, Column : Positive := 1)
         return Source_Errors.Source_Error
      is
        (Source_Errors.With_File
           (Source_Errors.Make (Message, Line, Column), File));

      --  Reads one file into the namespace, or marks the name it stands for
      --  failed.
      procedure Load_File (Path, Name : String) is
         Stem    : constant String :=
           Name (Name'First .. Name'Last - Extension'Length);
         Content : constant File_System.Maybe_Content := Files.Read (Path);
      begin
         if Namespaces.Has_Failed (Report.Definitions, Stem) then
            Problem
              (Error_In
                 (Path,
                  "'" & Stem & "' is also the name of a file that failed"));
            return;
         elsif not Content.Found then
            Fail
              (Stem,
               Error_In
                 (Path,
                  "cannot be read: it is missing, unreadable or larger than"
                  & Natural'Image (File_System.Max_File_Size / 1024)
                  & " KiB"));
            return;
         end if;
         declare
            Parsed : constant Parser.Parse_Results.Result :=
              Parser.Parse_Source (To_String (Content.Value));
         begin
            if not Parser.Parse_Results.Is_Success (Parsed) then
               Fail
                 (Stem,
                  Source_Errors.With_File
                    (Parser.Parse_Results.Error (Parsed), Path));
               return;
            end if;
            declare
               Item     : constant Syntax.Definition :=
                 Parser.Parse_Results.Value (Parsed);
               Declared : constant String := To_String (Item.Name.Name);
            begin
               if Declared /= Stem then
                  Fail
                    (Stem,
                     Error_In
                       (Path,
                        "the file name must be the name it declares: '"
                        & Stem & "' declares '" & Declared & "'",
                        Item.Name.Line, Item.Name.Column));
               elsif Namespaces.Contains (Report.Definitions, Stem) then
                  declare
                     Other : constant String :=
                       To_String
                         (Namespaces.Element (Report.Definitions, Stem).Path);
                  begin
                     if Other /= Path then
                        Fail
                          (Stem,
                           Error_In
                             (Path,
                              "'" & Stem & "' is defined in both " & Other
                              & " and " & Path
                              & ", so neither can be used",
                              Item.Name.Line, Item.Name.Column));
                     end if;
                  end;
               else
                  Namespaces.Insert (Report.Definitions, Path, Item);
               end if;
            end;
         end;
      end Load_File;
   begin
      for R of Roots loop
         declare
            Directory : constant String := To_String (R.Path);
         begin
            if not Files.Is_Directory (Directory) then
               if R.Required then
                  Problem
                    (Error_In (Directory, "search directory does not exist"));
               end if;
            else
               for Name of Files.List (Directory, Extension) loop
                  Load_File
                    (Join (Directory, To_String (Name)), To_String (Name));
               end loop;
            end if;
         end;
      end loop;
      return Report;
   end Load;

end Synapse.Pipeline.Definitions;
