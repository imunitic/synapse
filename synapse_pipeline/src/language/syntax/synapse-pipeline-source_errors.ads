with Ada.Strings.Unbounded;

--  What is wrong with a piece of pipeline source and where: a message and a
--  line and column counted from 1, and the file it is in when it came from
--  one. The lexer, the parser, the loading of definitions and their
--  validation all report in this one shape.

package Synapse.Pipeline.Source_Errors is

   type Source_Error is record
      Message : Ada.Strings.Unbounded.Unbounded_String;
      Line    : Positive := 1;
      Column  : Positive := 1;
      File    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Make
     (Message : String; Line, Column : Positive) return Source_Error;

   --  The same error, said to be in File.
   function With_File
     (Error : Source_Error; File : String) return Source_Error;

   --  `line:column: message`, or `file:line:column: message` with a file.
   function Image (Error : Source_Error) return String;

end Synapse.Pipeline.Source_Errors;
