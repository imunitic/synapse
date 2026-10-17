with Ada.Strings.Unbounded;

with Synapse.Ports.Byte_Source;

--  A text held in memory as a byte source: for an index already in memory,
--  and for tests.

package Synapse.Adapters.Memory_Byte_Source is

   type Source is limited new Ports.Byte_Source.Source with private;

   function Create (Content : String) return Source;

   overriding function Size
     (S : in out Source) return Ports.Byte_Source.Offset;

   overriding function Read
     (S : in out Source; From : Ports.Byte_Source.Offset; Count : Positive)
      return String;

private

   type Source is limited new Ports.Byte_Source.Source with record
      Content : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Adapters.Memory_Byte_Source;
