with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Results;

--  What a step hands back: its result, in one fixed shape that a pipeline
--  checks before it acts on any of it.
--
--    {"outcome": "Approved", "summary": "what happened", "data": {...}}
--
--  `outcome` is a word the pipeline's guards can test and is never empty;
--  `summary` is for a person; `data` is an object whose fields the step's own
--  instructions describe. There is nothing else: a result with another member
--  is refused, so that a guard has exactly three things to read.

package Synapse.Pipeline.Envelopes is

   package JSON renames Synapse.Core.JSON;

   type Envelope is record
      Outcome : Ada.Strings.Unbounded.Unbounded_String;
      Summary : Ada.Strings.Unbounded.Unbounded_String;
      Data    : JSON.Value := JSON.Make_Object ([1 .. 0 => <>]);
   end record;

   function To_JSON (Item : Envelope) return JSON.Value;

   function To_Text (Item : Envelope) return String;

   --  The envelope as a JSON Schema, for a harness that can be told what to
   --  answer with. It says what the checks below accept and nothing else.
   function Schema return JSON.Value;

   --  What is wrong with a result, said by where in it.
   package Envelope_Results is new Synapse.Core.Results
     (Envelope, Ada.Strings.Unbounded.Unbounded_String);

   function From_JSON
     (Document : JSON.Value) return Envelope_Results.Result;

   --  The envelope in a text that is exactly one JSON document.
   function Parse (Text : String) return Envelope_Results.Result
   with Pre => Text'Last < Positive'Last;

end Synapse.Pipeline.Envelopes;
