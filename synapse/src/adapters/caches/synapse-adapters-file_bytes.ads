--  Whole files as text, byte for byte.

package Synapse.Adapters.File_Bytes is

   --  The file is larger than the limit given to Read.
   Too_Large : exception;

   --  The contents of the file at Path. Ada.IO_Exceptions are raised for a
   --  file that cannot be opened or read; Too_Large for one over Limit bytes.
   function Read (Path : String; Limit : Natural) return String;

   --  Creates or replaces the file at Path with Content.
   procedure Write (Path, Content : String);

   --  The path with `/` between its parts, whatever the platform's own
   --  separator is: the form paths take in the graph, in output and in the
   --  tests. A path that already uses `/` comes back as it is.
   function Slashed (Path : String) return String;

   --  The directory for temporary files: $TMPDIR, $TMP or $TEMP when set to
   --  a directory, else /tmp when there is one, else the current directory.
   --  No trailing separator.
   function Temp_Dir return String;

   --  A new, empty file in Temp_Dir named `synapse-...tmp`, holding Content
   --  when it is not empty; its absolute path. The caller deletes it.
   function Temp_File (Content : String := "") return String;

end Synapse.Adapters.File_Bytes;
