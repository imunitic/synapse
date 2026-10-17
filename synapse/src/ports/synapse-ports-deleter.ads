--  Removing a note and turning every link to it into plain text, as one
--  capability, so the vault stays consistent. A separate capability from the
--  store: not every store has a delete, or links to rewrite.

package Synapse.Ports.Deleter is

   type Deleter is limited interface;

   --  Path is a full vault-relative path. Raises Store.Node_Not_Found when it
   --  holds nothing.
   procedure Delete (D : in out Deleter; Path : String) is abstract;

end Synapse.Ports.Deleter;
