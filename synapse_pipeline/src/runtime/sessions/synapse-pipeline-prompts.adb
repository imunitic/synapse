with Ada.Strings.Unbounded;

with Synapse.Pipeline.Outcomes;

package body Synapse.Pipeline.Prompts is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;
   package Outcome_Words renames Synapse.Pipeline.Outcomes;

   LF : constant Character := Character'Val (10);

   --  What the reply says about `summary` and `data`, the same whatever the
   --  outcome may be.
   Tail : constant String :=
     "`summary` says what you did, for a person. `data` is an object "
     & "holding anything the next step needs, and may be empty. The object "
     & "has no other members.";

   --  One line for each outcome: its word and what it means.
   function Listed (Declared : JSON.Value) return String is
      Lines : Unbounded_String;
   begin
      for I in 1 .. JSON.Length (Declared) loop
         Append
           (Lines,
            "- " & JSON.Member_Key (Declared, I) & ": "
            & JSON.As_String (JSON.Member_At (Declared, I)) & LF);
      end loop;
      return To_String (Lines);
   end Listed;

   function Build
     (Role            : String;
      Assignment      : String;
      Step            : String;
      Initial_Input   : JSON.Value;
      Previous_Output : JSON.Value;
      Outcomes        : JSON.Value := JSON.Null_Value) return String
   is
      Text : Unbounded_String;

      procedure Paragraph (Item : String) is
      begin
         if Item'Length > 0 then
            Append (Text, Item & LF & LF);
         end if;
      end Paragraph;
   begin
      Paragraph (Role);
      Paragraph (Assignment);
      Paragraph
        ("You are running as the step " & Step & " of an automated pipeline. "
         & "Nobody is available to answer questions, so make reasonable "
         & "decisions and carry on.");
      if JSON.Kind_Of (Initial_Input) /= JSON.JSON_Null then
         Paragraph
           ("The pipeline was started with this input:" & LF
            & JSON.To_String (Initial_Input));
      end if;
      if JSON.Kind_Of (Previous_Output) /= JSON.JSON_Null then
         Paragraph
           ("The step before yours reported this result:" & LF
            & JSON.To_String (Previous_Output));
      end if;
      if Outcome_Words.Is_Declared (Outcomes) then
         Paragraph
           ("When you are done, reply with one JSON object and nothing "
            & "else: no text before or after it and no code fence." & LF
            & "{""outcome"": ""<one of the outcomes below>"", ""summary"": "
            & """<text>"", ""data"": {}}" & LF
            & "`outcome` is exactly one of these words, the one that says "
            & "what actually happened:" & LF & Listed (Outcomes) & LF
            & "The pipeline decides which step runs next from it, so report "
            & "what is true, not what would be convenient. " & Tail);
      else
         Paragraph
           ("When you are done, reply with one JSON object and nothing "
            & "else: no text before or after it and no code fence." & LF
            & "{""outcome"": ""<one word>"", ""summary"": ""<text>"", "
            & """data"": {}}" & LF
            & "`outcome` is one word naming what actually happened, never "
            & "empty. The pipeline decides which step runs next from it, so "
            & "report what is true, not what would be convenient. " & Tail);
      end if;
      return To_String (Text);
   end Build;

end Synapse.Pipeline.Prompts;
