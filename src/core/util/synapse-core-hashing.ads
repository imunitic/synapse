with Synapse.Core.Graph_Model;

--  The two hashes a node is made of: a file's git blob hash, and SHA-256.

package Synapse.Core.Hashing with
  SPARK_Mode => Off
is

   --  Git's object hash of a file's content: the SHA-1 of `blob`, a space,
   --  the decimal length, a NUL and the content. It is computed here and not
   --  by `git hash-object`, which costs a process per batch and fails the
   --  whole batch on one file that is gone.
   function Blob_Hash (Content : String) return Graph_Model.Hash;

   --  The same hash as 40 lowercase hexadecimal digits, the form a node
   --  stores.
   function Blob_Hash_Hex (Content : String) return String with
     Post => Blob_Hash_Hex'Result'Length = 40;

     --  SHA-256 as 32 bytes, how an index stores it: half the size of its hex,
     --  and compared as bytes.
   type Digest is array (1 .. 32) of Natural range 0 .. 255;

   function Sha256_Raw (Content : String) return Digest;

   --  SHA-256 as 64 lowercase hexadecimal digits.
   function Sha256_Hex (Content : String) return String with
     Post => Sha256_Hex'Result'Length = 64;

end Synapse.Core.Hashing;
