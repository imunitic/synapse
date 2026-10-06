with GNAT.SHA1;
with GNAT.SHA256;

package body Synapse.Core.Hashing is

   function Blob_Hash_Hex (Content : String) return String is
      Length  : constant String   := Natural'Image (Content'Length);
      Context : GNAT.SHA1.Context := GNAT.SHA1.Initial_Context;
   begin
      GNAT.SHA1.Update (Context, "blob" & Length & Character'Val (0));
      GNAT.SHA1.Update (Context, Content);
      return GNAT.SHA1.Digest (Context);
   end Blob_Hash_Hex;

   function Blob_Hash (Content : String) return Graph_Model.Hash is
   begin
      return Graph_Model.Hash_From_Hex (Blob_Hash_Hex (Content)).Value;
   end Blob_Hash;

   function Sha256_Hex (Content : String) return String is
     (GNAT.SHA256.Digest (Content));

end Synapse.Core.Hashing;
