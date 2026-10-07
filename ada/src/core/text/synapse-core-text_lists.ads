with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  The two collections of text the search packages pass around.

package Synapse.Core.Text_Lists is

   package Vectors is new
     Ada.Containers.Vectors (Positive, Ada.Strings.Unbounded.Unbounded_String,
                             Ada.Strings.Unbounded."=");

   subtype Vector is Vectors.Vector;

   package Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   subtype Set is Sets.Set;

end Synapse.Core.Text_Lists;
