package body Synapse.Pipeline.Source_Errors is

   use Ada.Strings.Unbounded;

   function Trimmed (N : Natural) return String is
      Text : constant String := Natural'Image (N);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Trimmed;

   function Make
     (Message : String; Line, Column : Positive) return Source_Error
   is
     (Message => To_Unbounded_String (Message), Line => Line,
      Column  => Column, File => <>);

   function With_File
     (Error : Source_Error; File : String) return Source_Error
   is
     (Message => Error.Message, Line => Error.Line, Column => Error.Column,
      File    => To_Unbounded_String (File));

   function Image (Error : Source_Error) return String is
     ((if Length (Error.File) = 0 then "" else To_String (Error.File) & ":")
      & Trimmed (Error.Line) & ":" & Trimmed (Error.Column) & ": "
      & To_String (Error.Message));

end Synapse.Pipeline.Source_Errors;
