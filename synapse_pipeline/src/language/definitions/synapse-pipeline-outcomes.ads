with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;

--  The outcomes a step may declare: the words it can end with, each with a
--  line saying what it means, written as a JSON object from word to meaning.
--  A step that declares none ends with any word.
--
--  A word is written the way a name is: a letter and then letters, digits and
--  underscores, so that a guard can name it bare. The words that are keywords
--  or the end of a run are not words.

package Synapse.Pipeline.Outcomes is

   package JSON renames Synapse.Core.JSON;

   --  Whether Text can be an outcome.
   function Is_Word (Text : String) return Boolean;

   --  What is wrong with Declared as the value of an `Outcomes` attribute, or
   --  nothing: it must be an object with at least one member, every key a
   --  word and every value a one-line string that is not empty.
   function Problem (Declared : JSON.Value)
      return Synapse.Core.Optional_Text.Option;

   --  Whether Declared, as given by a step, declares outcomes at all.
   function Is_Declared (Declared : JSON.Value) return Boolean;

   --  Whether Word is one of the words Declared holds.
   function Has_Word (Declared : JSON.Value; Word : String) return Boolean;

   --  What is wrong with Word as the outcome of a step that declared
   --  Declared, or nothing: it says which words there are. Nothing as well
   --  when the step declared none.
   function Violation (Declared : JSON.Value; Word : String)
      return Synapse.Core.Optional_Text.Option;

   --  The guard that holds when a result's outcome is Word: the one a bare
   --  name in a `When` stands for.
   function Test_For (Word : String) return JSON.Value;

   --  The word a guard tests the outcome against and nothing else, or nothing
   --  when the guard is any other rule. Exactly the guards Test_For makes.
   function Tested_Word (Guard : JSON.Value)
      return Synapse.Core.Optional_Text.Option;

end Synapse.Pipeline.Outcomes;
