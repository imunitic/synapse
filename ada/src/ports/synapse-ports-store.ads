with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;

--  Where nodes (notes, graph nodes) are read, written, listed and searched.
--  A node is named by a `/`-separated relative path. Implementations live
--  under Synapse.Adapters.

package Synapse.Ports.Store is

   use Ada.Strings.Unbounded;

   --  A transport failure: a disk error, an unreachable endpoint. The message
   --  says what failed.
   Store_Failure : exception;

   --  A node name that could address something outside the store.
   Unsafe_Node : exception;

   type Maybe_Text (Found : Boolean := False) is record
      case Found is
         when True =>
            Text : Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  What a backend said about a write beyond plain success: an anticipated
   --  rejection, not a failure. Status and Body_Text are HTTP-shaped, for the
   --  one kind of backend that can answer no; a file store always accepts
   --  and leaves them zero and empty.
   type Write_Result is record
      Accepted  : Boolean := True;
      Status    : Natural := 0;
      Body_Text : Unbounded_String;
   end record;

   --  A search hit: a node, how well it matches (higher is better) and one
   --  line of the node that shows why.
   type Hit is record
      Node    : Unbounded_String;
      Score   : Float;
      Context : Unbounded_String;
   end record;

   package Hit_Vectors is new Ada.Containers.Vectors (Positive, Hit);

   type Store is limited interface;

   --  Nothing when the node does not exist.
   function Read (S : in out Store; Node : String) return Maybe_Text
   is abstract;

   function Write
     (S : in out Store; Node, Content : String) return Write_Result
   is abstract;

   --  Every node name.
   function List (S : in out Store) return Core.Text_Lists.Vector is abstract;

   --  The nodes whose text matches Query, with their scores.
   function Search
     (S : in out Store; Query : String) return Hit_Vectors.Vector
   is abstract;

end Synapse.Ports.Store;
