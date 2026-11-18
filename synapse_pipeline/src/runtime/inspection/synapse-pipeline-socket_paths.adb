with Ada.Strings;
with Ada.Strings.Fixed;

package body Synapse.Pipeline.Socket_Paths is

   use type Interfaces.Unsigned_64;

   Offset_Basis : constant Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   Prime        : constant Interfaces.Unsigned_64 := 16#0000_0100_0000_01B3#;
   Hex          : constant String := "0123456789abcdef";

   function Fnv1a_64_Hex (Text : String) return String is
      Hash   : Interfaces.Unsigned_64 := Offset_Basis;
      Rest   : Interfaces.Unsigned_64;
      Result : String (1 .. 16);
   begin
      for C of Text loop
         Hash := (Hash xor Interfaces.Unsigned_64 (Character'Pos (C))) * Prime;
      end loop;
      Rest := Hash;
      for I in reverse Result'Range loop
         Result (I) := Hex (Hex'First + Natural (Rest and 16#F#));
         Rest := Interfaces.Shift_Right (Rest, 4);
      end loop;
      return Result;
   end Fnv1a_64_Hex;

   function Short_Folder (Uid : User_Id) return String is
     ("/tmp/synapse-pipeline-"
      & Ada.Strings.Fixed.Trim (User_Id'Image (Uid), Ada.Strings.Left));

   function Endpoint (Record_Folder : String; Uid : User_Id) return String is
      In_Record : constant String := Record_Folder & "/" & Socket_Name;
   begin
      if In_Record'Length <= Max_Length then
         return In_Record;
      end if;
      return Short_Folder (Uid) & "/" & Fnv1a_64_Hex (Record_Folder) & ".sock";
   end Endpoint;

   function Is_Short (Endpoint : String; Uid : User_Id) return Boolean is
      Folder : constant String := Short_Folder (Uid) & "/";
   begin
      return Endpoint'Length > Folder'Length
        and then Endpoint
                   (Endpoint'First .. Endpoint'First + Folder'Length - 1)
                 = Folder;
   end Is_Short;

end Synapse.Pipeline.Socket_Paths;
