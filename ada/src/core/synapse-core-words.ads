with Synapse.Core.Text_Lists;

--  Splitting text into words the way identifiers are written, and which of
--  those words are worth searching for.

package Synapse.Core.Words is

   --  The words of Text, lowercased: a run of capitals followed by lowercase
   --  letters and digits is one word (`HTTPServer` is `httpserver`, while
   --  `HttpClient` is `http` and `client`), a run of lowercase letters and
   --  digits is one word, a run of bytes from 16#80# up is one word, and
   --  every other character separates.
   --  Only ASCII letters are lowercased.
   function Split_Words (Text : String) return Text_Lists.Vector;

   --  A word is kept when it has at least four characters, is not made only
   --  of digits and is not a stopword.
   function Keep (Word : String; Stopwords : Text_Lists.Set) return Boolean;

   --  The kept words of Query, each once, in the order first seen.
   function Query_Terms
     (Query : String; Stopwords : Text_Lists.Set) return Text_Lists.Vector;

   --  How much a word tells: `D / (D + Docs_With_Term)` with
   --  `D = max (2, Docs / max (1, K))`, from 1.0 (in no document) down
   --  towards 0.0. K scales what counts as rare.
   function Distinctiveness
     (Docs_With_Term, Docs, K : Natural) return Long_Float;

end Synapse.Core.Words;
