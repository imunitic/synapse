with Interfaces.C;
with System;

with GNAT.OS_Lib;

package body Synapse.Pipeline.Socket_Folders is

   use type Interfaces.C.int;
   use type Interfaces.C.size_t;
   use type System.Address;

   function C_Getuid return Interfaces.C.unsigned
   with Import, Convention => C, External_Name => "getuid";

   function C_Realpath
     (Path : Interfaces.C.char_array; Resolved : System.Address)
      return System.Address
   with Import, Convention => C, External_Name => "realpath";

   function C_Mkdir
     (Path : Interfaces.C.char_array; Mode : Interfaces.C.unsigned)
      return Interfaces.C.int
   with Import, Convention => C, External_Name => "mkdir";

   --  Unlike chown, does not follow a symbolic link.
   function C_Lchown
     (Path : Interfaces.C.char_array; Owner, Group : Interfaces.C.unsigned)
      return Interfaces.C.int
   with Import, Convention => C, External_Name => "lchown";

   function C_Chmod
     (Path : Interfaces.C.char_array; Mode : Interfaces.C.unsigned)
      return Interfaces.C.int
   with Import, Convention => C, External_Name => "chmod";

   --  At least PATH_MAX, which is 1024 on macOS and 4096 on Linux.
   Real_Path_Size : constant := 4096;

   --  As a uid_t or gid_t, (unsigned) -1 leaves that id as it is.
   Unchanged : constant Interfaces.C.unsigned := Interfaces.C.unsigned'Last;

   function User_Id return Socket_Paths.User_Id is
     (Socket_Paths.User_Id (C_Getuid));

   function Real_Path (Path : String) return String is
      Buffer : aliased Interfaces.C.char_array (0 .. Real_Path_Size - 1) :=
        [others => Interfaces.C.nul];
      Got    : constant System.Address :=
        C_Realpath (Interfaces.C.To_C (Path), Buffer'Address);
   begin
      if Got = System.Null_Address then
         return Path;
      end if;
      return Interfaces.C.To_Ada (Buffer);
   end Real_Path;

   --  The folder is in a directory every user can write to, such as /tmp,
   --  so another user may have made it, or put a symbolic link there. lchown
   --  to this user succeeds only on an entry this user already owns, and
   --  does not follow a link. Once the entry is known to be this user's, the
   --  sticky bit of such a directory keeps anyone else from renaming or
   --  replacing it, so what is checked after cannot change underneath.
   function Make_Private (Path : String) return String is
      C_Path  : constant Interfaces.C.char_array := Interfaces.C.To_C (Path);
      Ignored : constant Interfaces.C.int := C_Mkdir (C_Path, 8#700#);
   begin
      if C_Lchown (C_Path, C_Getuid, Unchanged) /= 0 then
         return Path & " could not be made, or another user owns it";
      elsif GNAT.OS_Lib.Is_Symbolic_Link (Path)
        or else not GNAT.OS_Lib.Is_Directory (Path)
      then
         return Path & " is not a directory";
      elsif C_Chmod (C_Path, 8#700#) /= 0 then
         return Path & " could not be made private";
      end if;
      return "";
   end Make_Private;

end Synapse.Pipeline.Socket_Folders;
