with Ada.Strings.Unbounded;

package body Synapse.Pipeline.Prompts is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   function Build
     (Role            : String;
      Assignment      : String;
      Step            : String;
      Initial_Input   : JSON.Value;
      Previous_Output : JSON.Value) return String
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
      Paragraph
        ("When you are done, reply with one JSON object and nothing else: no "
         & "text before or after it and no code fence." & LF
         & "{""outcome"": ""<one word>"", ""summary"": ""<text>"", "
         & """data"": {}}" & LF
         & "`outcome` is one word naming what actually happened, never "
         & "empty. The pipeline decides which step runs next from it, so "
         & "report what is true, not what would be convenient. `summary` "
         & "says what you did, for a person. `data` is an object holding "
         & "anything the next step needs, and may be empty. The object has "
         & "no other members.");
      return To_String (Text);
   end Build;

end Synapse.Pipeline.Prompts;
