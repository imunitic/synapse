--  A value, or nothing: for a lookup whose absence is an answer and not a
--  failure. One generic in place of a record type per lookup. What can fail
--  with a reason to give uses `Results` instead.
--
--  `Found` says whether there is a value, and the value cannot be read from
--  an option that has none: the check is the discriminant's.

generic
   type Value_Type is private;
package Synapse.Core.Options is

   type Option (Found : Boolean := False) is record
      case Found is
         when True =>
            Value : Value_Type;

         when False =>
            null;
      end case;
   end record;

   None : constant Option := (Found => False);

   function Of_Value (Item : Value_Type) return Option is
     (Found => True, Value => Item);

end Synapse.Core.Options;
