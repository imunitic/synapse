with Ada.IO_Exceptions;
with Ada.Text_IO;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.Schema_YAML;

package body Synapse.Adapters.Schema_Loader is

   use Ada.Strings.Unbounded;

   Largest_Schema     : constant := 1_024 * 1_024;
   Largest_Vocabulary : constant := 4 * 1_024 * 1_024;

   --  `EMPTY_DOCUMENT` as `EmptyDocument`: how the faults are named.
   function Camel (Image : String) return String is
      Result : Unbounded_String;
      Upper  : Boolean := True;
   begin
      for C of Image loop
         if C = '_' then
            Upper := True;
         elsif Upper then
            Append (Result, C);
            Upper := False;
         else
            Append (Result, Character'Val (Character'Pos (C) + 32));
         end if;
      end loop;
      return To_String (Result);
   end Camel;

   function Failed (Name : String) return Load_Result is
     (Load_Results.Failure (To_Unbounded_String (Name)));

   function Load_Schema (V : Variables; Schema_Id : String) return Load_Result
   is
      Root : constant Synapse.Ports.Variables.Maybe_Value :=
        V.Get ("SYNAPSE_CONTENT_ROOT");
   begin
      if not Root.Found or else Length (Root.Value) = 0 then
         return Failed ("ContentRootMissing");
      end if;

      declare
         Source : constant String                        :=
           File_Bytes.Read
             (To_String (Root.Value) & "/schema/" & Schema_Id & ".yaml",
              Largest_Schema);
         Base   : constant Core.Schema_YAML.Parse_Result :=
           Core.Schema_YAML.Parse (Source);
      begin
         if not Core.Schema_YAML.Parse_Results.Is_Success (Base) then
            return
              Failed
                (Camel
                   (Core.Schema_YAML.Parse_Fault'Image
                      (Core.Schema_YAML.Parse_Results.Error (Base).Fault)));
         end if;

         declare
            Found : constant Conf_Files.Maybe_Path :=
              Conf_Files.Resolve_Conf_Path
                (V, "schema-overrides/" & Schema_Id & ".yaml");
         begin
            if not Found.Found then
               return
                 Load_Results.Success
                   (Core.Schema_YAML.Parse_Results.Value (Base));
            end if;
            declare
               Patch : constant Core.Schema_YAML.Parse_Result :=
                 Core.Schema_YAML.Parse
                   (File_Bytes.Read (To_String (Found.Value), Largest_Schema));
            begin
               if not Core.Schema_YAML.Parse_Results.Is_Success (Patch) then
                  return
                    Failed
                      (Camel
                         (Core.Schema_YAML.Parse_Fault'Image
                            (Core.Schema_YAML.Parse_Results.Error (Patch)
                               .Fault)));
               end if;
               declare
                  Merged : constant Core.Schema_YAML.Merge_Result :=
                    Core.Schema_YAML.Merge
                      (Core.Schema_YAML.Parse_Results.Value (Base),
                       Core.Schema_YAML.Parse_Results.Value (Patch));
               begin
                  if not Core.Schema_YAML.Merge_Results.Is_Success (Merged)
                  then
                     return
                       Failed
                         (Camel
                            (Core.Schema_YAML.Merge_Fault'Image
                               (Core.Schema_YAML.Merge_Results.Error
                                  (Merged))));
                  end if;
                  return
                    Load_Results.Success
                      (Core.Schema_YAML.Merge_Results.Value (Merged));
               end;
            end;
         end;
      end;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         return Failed ("FileNotFound");
      when File_Bytes.Too_Large                                       =>
         return Failed ("StreamTooLong");
   end Load_Schema;

   function Load_Vocabulary (V : Variables; Name : String) return Maybe_Text is
      Found : constant Conf_Files.Maybe_Path :=
        Conf_Files.Resolve_Conf_Path (V, Name);
   begin
      if not Found.Found then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value =>
           To_Unbounded_String
             (File_Bytes.Read (To_String (Found.Value), Largest_Vocabulary)));
   exception
      when others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "synapse: unreadable vocabulary conf: " & To_String (Found.Value));
         return (Found => False);
   end Load_Vocabulary;

   function Is_Safe_Schema_Id (Id : String) return Boolean is
      Segments : Natural := 0;
      Start    : Natural := Id'First;
   begin
      if Id'Length = 0 or else Id (Id'First) = '/'
        or else (for some C of Id => C = '\')
      then
         return False;
      end if;
      for I in Id'First .. Id'Last + 1 loop
         if I > Id'Last or else Id (I) = '/' then
            declare
               Segment : constant String := Id (Start .. I - 1);
            begin
               if Segment'Length = 0 or else Segment = "."
                 or else Segment = ".."
                 or else not
                 (for all C of Segment =>
                    C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_')
               then
                  return False;
               end if;
            end;
            Segments := Segments + 1;
            Start    := I + 1;
         end if;
      end loop;
      return Segments >= 2;
   end Is_Safe_Schema_Id;

end Synapse.Adapters.Schema_Loader;
