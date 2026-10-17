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

   function Sha256_Raw (Content : String) return Digest is
      Hex    : constant String := GNAT.SHA256.Digest (Content);
      Result : Digest;

      function Value (C : Character) return Natural is
        (if C in '0' .. '9' then Character'Pos (C) - Character'Pos ('0')
         else Character'Pos (C) - Character'Pos ('a') + 10);
   begin
      for I in Result'Range loop
         Result (I) := Value (Hex (2 * I - 1)) * 16 + Value (Hex (2 * I));
      end loop;
      return Result;
   end Sha256_Raw;

   function Sha256_Hex (Content : String) return String is
     (GNAT.SHA256.Digest (Content));

end Synapse.Core.Hashing;
