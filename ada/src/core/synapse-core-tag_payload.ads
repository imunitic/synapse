with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Graph_Model;

--  The payload of a tags-cache entry: a list of tags and the bytes it is
--  stored as. A tag is stored as itself, a small length-prefixed record, one
--  after another with no framing between them but their own lengths: the
--  entry knows its total payload length, so a reader reads records until the
--  bytes run out. A tag's name, kind and expression are held whole, any bytes
--  they contain included, since no delimiter is involved.
--
--  A record is the role (1 byte: 0 def, 1 ref), the line (4), the name (2 and
--  its bytes), the kind (2 and its bytes) and the expression (4 and its
--  bytes), all lengths and numbers least significant byte first. No tags is
--  no bytes, which is the meaning of an entry that was parsed and declared
--  nothing.

package Synapse.Core.Tag_Payload is

   Longest_Name : constant := 65_535;

   --  One tag as a record. The name and the kind must fit their 2-byte
   --  lengths.
   function Encode_One (Item : Graph_Model.Tag) return String with
     Pre =>
      Ada.Strings.Unbounded.Length (Item.Name) <= Longest_Name
      and then Ada.Strings.Unbounded.Length (Item.Kind) <= Longest_Name;

   package Tag_Vectors is new Ada.Containers.Vectors
     (Positive, Graph_Model.Tag, Graph_Model."=");

   function Encode (Tags : Tag_Vectors.Vector) return String;

   type Maybe_Tag (Found : Boolean := False) is record
      case Found is
         when True =>
            Value : Graph_Model.Tag;

         when False =>
            null;
      end case;
   end record;

   --  The record that starts at Position of Bytes, with Position moved past
   --  it. None once every record has been read, and as soon as one is
   --  malformed (an unknown role, or a length that runs past the end): a
   --  corrupt payload stops silently and never reads garbage as the framing of
   --  the next record.
   procedure Next
     (Bytes : String; Position : in out Integer; Result : out Maybe_Tag);

   --  Every record that decodes, in order, up to the first that does not.
   function Decode (Bytes : String) return Tag_Vectors.Vector;

end Synapse.Core.Tag_Payload;
