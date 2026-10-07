with Ada.Containers.Vectors;

with Synapse.Core.Tag_Payload;
with Synapse.Core.Text_Lists;

--  Source files in, tags out. Implementations live under Synapse.Adapters.
--
--  Batch-shaped on purpose: loading a grammar dominates the cost of tagging
--  one file, so the port takes every path at once and an implementation
--  batches as it sees fit.

package Synapse.Ports.Extractor is

   --  A file that parsed to nothing differs from one with no grammar: the
   --  tags cache needs to know which, so a readable file is not tried again on
   --  every call.
   type Outcome_Kind is (With_Tags, Unsupported);

   type Outcome (Kind : Outcome_Kind := Unsupported) is record
      case Kind is
         when With_Tags =>
            Tags : Core.Tag_Payload.Tag_Vectors.Vector;

         when Unsupported =>
            null;
      end case;
   end record;

   package Outcome_Vectors is new Ada.Containers.Vectors (Positive, Outcome);

   type Extractor is limited interface;

   --  One outcome per path, in the order of Paths. A path is relative to Root
   --  unless it is absolute.
   function Extract
     (E : in out Extractor; Root : String; Paths : Core.Text_Lists.Vector)
      return Outcome_Vectors.Vector is abstract with
     Post'Class => Natural (Extract'Result.Length) = Natural (Paths.Length);

end Synapse.Ports.Extractor;
