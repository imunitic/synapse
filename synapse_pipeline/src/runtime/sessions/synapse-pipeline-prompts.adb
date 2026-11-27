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

   --  A value as the input list writes it on its field's line: a string as
   --  it is, anything else as JSON.
   function Plain (Item : JSON.Value) return String is
     (if JSON.Kind_Of (Item) = JSON.JSON_String then JSON.As_String (Item)
      else JSON.To_String (Item));

   --  Given written as the list of the fields Declared names, each with its
   --  description.
   function Listed_Input (Declared, Given : JSON.Value) return String is
      Fields : constant JSON.Value := JSON.Member_Value (Declared, "fields");
      Lines  : Unbounded_String;
   begin
      for I in 1 .. JSON.Length (Fields) loop
         declare
            Name  : constant String := JSON.Member_Key (Fields, I);
            Rules : constant JSON.Value := JSON.Member_At (Fields, I);
            Found : constant Boolean :=
              JSON.Kind_Of (Given) = JSON.JSON_Object
              and then JSON.Has_Member (Given, Name)
              and then JSON.Kind_Of (JSON.Member_Value (Given, Name))
                       /= JSON.JSON_Null;
            Value : constant JSON.Value :=
              (if Found then JSON.Member_Value (Given, Name)
               else JSON.Null_Value);
         begin
            Append (Lines, LF & "- " & Name & ":");
            if not Found
              or else (JSON.Kind_Of (Value) = JSON.JSON_Array
                       and then JSON.Length (Value) = 0)
            then
               Append (Lines, " (not given)");
            elsif JSON.Kind_Of (Value) = JSON.JSON_Array then
               for J in 1 .. JSON.Length (Value) loop
                  Append
                    (Lines, LF & "  - " & Plain (JSON.Element (Value, J)));
               end loop;
            else
               Append (Lines, " " & Plain (Value));
            end if;
            Append
              (Lines,
               LF & "  "
               & JSON.As_String (JSON.Member_Value (Rules, "description")));
         end;
      end loop;
      return To_String (Lines);
   end Listed_Input;

   function Parts
     (Role            : String;
      Assignment      : String;
      Step            : String;
      Initial_Input   : JSON.Value;
      Previous_Output : JSON.Value;
      Outcomes        : JSON.Value := JSON.Null_Value;
      Interactive     : Boolean := False;
      Declared_Input  : JSON.Value := JSON.Null_Value)
      return Part_Vectors.Vector
   is
      Result : Part_Vectors.Vector;

      procedure Paragraph (Kind : Part_Kind; Item : String) is
      begin
         if Item'Length > 0 then
            Result.Append (Part'(Kind, To_Unbounded_String (Item)));
         end if;
      end Paragraph;
   begin
      Paragraph (Role_Part, Role);
      Paragraph (Assignment_Part, Assignment);
      Paragraph
        (Protocol_Part,
         "You are running as the step " & Step & " of an automated pipeline. "
         & (if Interactive then
              "A person can answer in this terminal. When you need a "
              & "decision or a permission that you cannot reasonably make "
              & "yourself, ask in plain text and wait for the answer, and "
              & "give the reply below only when you are done, never with a "
              & "question. If you are stuck, cannot finish, or a command was "
              & "denied, do not end with an outcome that says so while the "
              & "person can help: say what stopped you and what you need, ask "
              & "in plain text, wait, and carry on from the answer. A message "
              & "that tells you to stop and explain to the user means: "
              & "explain it here and wait. Report such an outcome only when "
              & "the person tells you to stop."
            else
              "Nobody is available to answer questions, so make reasonable "
              & "decisions and carry on."));
      if JSON.Kind_Of (Declared_Input) /= JSON.JSON_Null then
         Paragraph
           (Input_Part,
            "The pipeline was started with this input:"
            & Listed_Input (Declared_Input, Initial_Input));
      elsif JSON.Kind_Of (Initial_Input) /= JSON.JSON_Null then
         Paragraph
           (Input_Part,
            "The pipeline was started with this input:" & LF
            & JSON.To_String (Initial_Input));
      end if;
      if JSON.Kind_Of (Previous_Output) /= JSON.JSON_Null then
         Paragraph
           (Previous_Part,
            "The step before yours reported this result:" & LF
            & JSON.To_String (Previous_Output));
      end if;
      if Outcome_Words.Is_Declared (Outcomes) then
         Paragraph
           (Contract_Part,
            "When you are done, reply with one JSON object and nothing "
            & "else: no text before or after it and no code fence." & LF
            & "{""outcome"": ""<one of the outcomes below>"", ""summary"": "
            & """<text>"", ""data"": {}}" & LF
            & "`outcome` is exactly one of these words, the one that says "
            & "what actually happened:" & LF & Listed (Outcomes) & LF
            & "The pipeline decides which step runs next from it, so report "
            & "what is true, not what would be convenient. " & Tail);
      else
         Paragraph
           (Contract_Part,
            "When you are done, reply with one JSON object and nothing "
            & "else: no text before or after it and no code fence." & LF
            & "{""outcome"": ""<one word>"", ""summary"": ""<text>"", "
            & """data"": {}}" & LF
            & "`outcome` is one word naming what actually happened, never "
            & "empty. The pipeline decides which step runs next from it, so "
            & "report what is true, not what would be convenient. " & Tail);
      end if;
      return Result;
   end Parts;

   function Text_Of (Parts : Part_Vectors.Vector) return String is
      Text : Unbounded_String;
   begin
      for Item of Parts loop
         Append (Text, Item.Text & LF & LF);
      end loop;
      return To_String (Text);
   end Text_Of;

   function Build
     (Role            : String;
      Assignment      : String;
      Step            : String;
      Initial_Input   : JSON.Value;
      Previous_Output : JSON.Value;
      Outcomes        : JSON.Value := JSON.Null_Value;
      Interactive     : Boolean := False;
      Declared_Input  : JSON.Value := JSON.Null_Value) return String
   is
     (Text_Of
        (Parts
           (Role, Assignment, Step, Initial_Input, Previous_Output, Outcomes,
            Interactive, Declared_Input)));

end Synapse.Pipeline.Prompts;
