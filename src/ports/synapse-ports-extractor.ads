with Ada.Containers.Vectors;

with Synapse.Core.Graph_Model;
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

   --  Where a tag's name is, as tree-sitter numbers it: rows and columns from
   --  zero, the end exclusive.
   type Span is record
      Start_Row : Natural;
      Start_Col : Natural;
      End_Row   : Natural;
      End_Col   : Natural;
   end record;

   --  A tag with the span of its name node, which the tags cache does not
   --  keep and the command line prints.
   type Located_Tag is record
      Item  : Core.Graph_Model.Tag;
      Where : Span;
   end record;

   package Located_Vectors is new Ada.Containers.Vectors
     (Positive, Located_Tag);

   type Located_Outcome (Kind : Outcome_Kind := Unsupported) is record
      case Kind is
         when With_Tags =>
            Tags : Located_Vectors.Vector;

         when Unsupported =>
            null;
      end case;
   end record;

   package Located_Outcome_Vectors is new Ada.Containers.Vectors
     (Positive, Located_Outcome);

   --  An extractor that can also say where each tag is.
   type Locating_Extractor is limited interface and Extractor;

   function Extract_Located
     (E     : in out Locating_Extractor; Root : String;
      Paths :        Core.Text_Lists.Vector)
      return Located_Outcome_Vectors.Vector is abstract with
     Post'Class =>
      Natural (Extract_Located'Result.Length) = Natural (Paths.Length);

end Synapse.Ports.Extractor;
