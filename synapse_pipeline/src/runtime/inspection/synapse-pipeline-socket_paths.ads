with Interfaces;

--  Where a run's inspector socket goes on a POSIX system. The path of a Unix
--  socket must fit in the fixed `sun_path` field of `sockaddr_un`: 104 bytes
--  on macOS, 108 on Linux. A path that fits stays in the run's record folder.
--  A longer one goes to a short folder only the user can use, named by a hash
--  of the record folder. The Rust and Node hosts of Synapse Desktop compute
--  the same path, byte for byte, so the three must change together.

package Synapse.Pipeline.Socket_Paths is

   --  The socket's name in the record folder.
   Socket_Name : constant String := "execution.sock";

   --  The longest path a socket is given, with room to spare under the
   --  operating systems' own limits.
   Max_Length : constant := 100;

   subtype User_Id is Interfaces.Unsigned_32;

   --  The 64-bit FNV-1a hash of the bytes of Text, as 16 lowercase hex
   --  digits.
   function Fnv1a_64_Hex (Text : String) return String
   with Post => Fnv1a_64_Hex'Result'Length = 16;

   --  The folder that holds the sockets whose paths would be too long:
   --  `/tmp/synapse-pipeline-<Uid>`.
   function Short_Folder (Uid : User_Id) return String;

   --  Where the run whose record folder is Record_Folder listens: in that
   --  folder when the path fits, else in Short_Folder (Uid), named by the
   --  hash of Record_Folder. Record_Folder is the folder's real path, as
   --  realpath(3) gives it, so that every program gets the same hash.
   function Endpoint (Record_Folder : String; Uid : User_Id) return String;

   --  Whether Endpoint is in Short_Folder (Uid).
   function Is_Short (Endpoint : String; Uid : User_Id) return Boolean;

end Synapse.Pipeline.Socket_Paths;
