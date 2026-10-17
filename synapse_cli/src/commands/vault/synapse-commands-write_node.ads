with Ada.Strings.Unbounded;

with Synapse.Commands.Context;

--  `write-node --title <t> --summary <s> --paths <file> --body <file>`:
--  hashes every source, computes the sources digest, records the baseline
--  commit, expands the crux directive, records and strips the groundings,
--  builds the sources mirror and writes the note through the vault's store.
--  Prints `<file>\t<n> files\t<digest>`. What cannot be written is refused and
--  not degraded: a crux path the node does not claim, a range outside the
--  file or past its cap, a listed file that is gone. Hand-written notes after
--  the generated region are carried over unchanged.
package Synapse.Commands.Write_Node is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   type Input is record
      Title      : Ada.Strings.Unbounded.Unbounded_String;
      Summary    : Ada.Strings.Unbounded.Unbounded_String;
      --  Repository relative paths, one per line.
      Paths_Text : Ada.Strings.Unbounded.Unbounded_String;
      --  The authored prose, without frontmatter.
      Body_Text  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Writes the node of Item in the namespace of Ctx. Line receives the one
   --  success line, which `push-nodes` prefixes with the node number.
   function Write
     (Env  :     Environment; Ctx : Context.Context; Item : Input;
      Line : out Ada.Strings.Unbounded.Unbounded_String) return Exit_Code;

end Synapse.Commands.Write_Node;
