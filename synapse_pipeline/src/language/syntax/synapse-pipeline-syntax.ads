with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;

--  What a definition file says, as the parser reads it and before anything
--  checks that it makes sense: the three kinds of definition, a pipeline's
--  steps and edges in the order they were written, and attribute lists whose
--  names are not yet known to be real. Every part carries the line and column
--  it came from, so that whatever is wrong with it later can be pointed at.

package Synapse.Pipeline.Syntax is

   --  A name, with where it was written: a step in an edge, the name of a
   --  definition, the name of an attribute.
   type Reference is record
      Name   : Ada.Strings.Unbounded.Unbounded_String;
      Line   : Positive := 1;
      Column : Positive := 1;
   end record;

   --  The right-hand side of `=>`.
   type Value_Kind is
     (Name_Value, String_Value, Integer_Value, JSON_Value);

   type Value (Kind : Value_Kind := Name_Value) is record
      Line   : Positive := 1;
      Column : Positive := 1;

      case Kind is
         when Name_Value =>
            Name : Ada.Strings.Unbounded.Unbounded_String;

         when String_Value =>
            Text : Ada.Strings.Unbounded.Unbounded_String;

         when Integer_Value =>
            Number : Long_Long_Integer := 0;

         when JSON_Value =>
            Source : Ada.Strings.Unbounded.Unbounded_String;
            Json   : Synapse.Core.JSON.Value;
      end case;
   end record;

   package Reference_Vectors is new Ada.Containers.Vectors
     (Positive, Reference);

   type Attribute is record
      Name : Reference;
      Item : Value;
   end record;

   package Attribute_Vectors is new Ada.Containers.Vectors
     (Positive, Attribute);

   --  `Name [attributes];` inside a pipeline.
   type Step is record
      Name       : Reference;
      Attributes : Attribute_Vectors.Vector;
   end record;

   package Step_Vectors is new Ada.Containers.Vectors (Positive, Step);

   --  `From -> To [attributes];`. A chain `A -> B -> C` is read as the edges
   --  A to B and B to C, each with the chain's attributes.
   type Edge is record
      From       : Reference;
      To         : Reference;
      Attributes : Attribute_Vectors.Vector;
   end record;

   package Edge_Vectors is new Ada.Containers.Vectors (Positive, Edge);

   type Definition_Kind is
     (Pipeline_Definition, System_Definition, Agent_Definition);

   --  The one definition a file holds.
   type Definition (Kind : Definition_Kind := Pipeline_Definition) is record
      Name : Reference;

      case Kind is
         when Pipeline_Definition =>
            Steps : Step_Vectors.Vector;
            Edges : Edge_Vectors.Vector;

         when System_Definition | Agent_Definition =>
            Attributes : Attribute_Vectors.Vector;
      end case;
   end record;

   --  The keyword that opens a definition of this kind.
   function Keyword (Kind : Definition_Kind) return String is
     (case Kind is
        when Pipeline_Definition => "Pipeline",
        when System_Definition   => "System",
        when Agent_Definition    => "Agent");

   --  Whether a name is one of those keywords, which no step may be called.
   function Is_Reserved (Name : String) return Boolean is
     (Name in "Pipeline" | "System" | "Agent");

end Synapse.Pipeline.Syntax;
