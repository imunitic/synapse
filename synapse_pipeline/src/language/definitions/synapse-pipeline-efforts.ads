with Synapse.Pipeline.Harnesses;

--  How much effort a step's model is asked to put in, checked against the
--  harness that runs the step. Claude and Codex each offer a fixed list,
--  compared without regard to case. OpenCode takes a variant, which belongs
--  to the model, so any name of a variant's shape is taken.

package Synapse.Pipeline.Efforts is

   --  Whether Harness takes Value as an effort. Claude and Codex compare
   --  without regard to case; OpenCode takes any variant name.
   function Is_Offered
     (Harness : Harnesses.Harness_Kind; Value : String) return Boolean;

   --  The efforts Harness offers, as "low, medium, high, xhigh, max", for
   --  messages. Empty for OpenCode, whose variants belong to the model.
   function Names (Harness : Harnesses.Harness_Kind) return String;

   --  Value as it is passed to Harness: lower case for Claude and Codex,
   --  as written for OpenCode.
   function Normalized
     (Harness : Harnesses.Harness_Kind; Value : String) return String;

end Synapse.Pipeline.Efforts;
