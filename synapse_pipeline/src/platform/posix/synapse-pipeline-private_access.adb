with Interfaces.C;

package body Synapse.Pipeline.Private_Access is

   function C_Chmod
     (Path : Interfaces.C.char_array; Mode : Interfaces.C.unsigned)
      return Interfaces.C.int
   with Import, Convention => C, External_Name => "chmod";

   --  Failing to say so is not reported: the path was just made by this
   --  program, in a directory only the user can enter.
   procedure Restrict (Path : String; Mode : Interfaces.C.unsigned) is
      Ignored : constant Interfaces.C.int :=
        C_Chmod (Interfaces.C.To_C (Path), Mode);
   begin
      null;
   end Restrict;

   procedure Directory (Path : String) is
   begin
      Restrict (Path, 8#700#);
   end Directory;

   procedure File (Path : String) is
   begin
      Restrict (Path, 8#600#);
   end File;

end Synapse.Pipeline.Private_Access;
