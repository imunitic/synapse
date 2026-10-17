--  Bytes by position: a file or a text read at an offset, so that a sorted
--  index of a gigabyte can be searched by reading the few blocks a bisection
--  lands on and never the whole of it.

package Synapse.Ports.Byte_Source is

   subtype Offset is Long_Long_Integer range 0 .. Long_Long_Integer'Last;

   type Source is limited interface;

   --  A source cannot be opened or read.
   Source_Failure : exception;

   --  The number of bytes.
   function Size (S : in out Source) return Offset is abstract;

   --  The Count bytes at From, fewer when the source ends first, none at or
   --  past its end.
   function Read
     (S : in out Source; From : Offset; Count : Positive)
      return String is abstract;

end Synapse.Ports.Byte_Source;
