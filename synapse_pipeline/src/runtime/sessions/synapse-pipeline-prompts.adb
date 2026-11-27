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
            & Outcome_Words.Meaning_Of
                (Declared, JSON.Member_Key (Declared, I)) & LF);
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

   --  One line for each field Fields maps, `- <name> (<type>, required or
   --  optional): <description>`, each started with Indent. A list of items
   --  with fields says so in its type and has its item fields under it.
   function Listed_Fields (Fields : JSON.Value; Indent : String) return String
   is
      Lines : Unbounded_String;
   begin
      for I in 1 .. JSON.Length (Fields) loop
         declare
            Name     : constant String := JSON.Member_Key (Fields, I);
            Rules    : constant JSON.Value := JSON.Member_At (Fields, I);
            Type_Of  : constant String :=
              JSON.As_String (JSON.Member_Value (Rules, "type"));
            Items    : constant JSON.Value :=
              (if JSON.Has_Member (Rules, "items")
               then JSON.Member_Value (Rules, "items") else JSON.Null_Value);
            Required : constant Boolean :=
              JSON.Has_Member (Rules, "required")
              and then JSON.Kind_Of (JSON.Member_Value (Rules, "required"))
                       = JSON.JSON_Boolean
              and then JSON.As_Boolean (JSON.Member_Value (Rules, "required"));
            Shown    : constant String :=
              (if JSON.Kind_Of (Items) = JSON.JSON_String
               then Type_Of & " of " & JSON.As_String (Items)
               elsif JSON.Kind_Of (Items) = JSON.JSON_Object
               then Type_Of & " of items with fields"
               else Type_Of);
         begin
            Append
              (Lines,
               Indent & "- " & Name & " (" & Shown & ", "
               & (if Required then "required" else "optional") & "): "
               & JSON.As_String (JSON.Member_Value (Rules, "description"))
               & LF);
            if JSON.Kind_Of (Items) = JSON.JSON_Object then
               Append
                 (Lines,
                  Listed_Fields
                    (JSON.Member_Value (Items, "fields"), Indent & "  "));
            end if;
         end;
      end loop;
      return To_String (Lines);
   end Listed_Fields;

   --  What to put in `data`: the fields of the step's Data, then those of
   --  each outcome in Outcomes that has `data`, under its word. Every line
   --  ends with a line feed; "" when nothing is declared.
   function Data_Contract (Outcomes, Data : JSON.Value) return String is
      Lines : Unbounded_String;
   begin
      if JSON.Kind_Of (Data) = JSON.JSON_Object then
         Append
           (Lines,
            "Put these fields in data:" & LF
            & Listed_Fields (JSON.Member_Value (Data, "fields"), ""));
      end if;
      if Outcome_Words.Is_Declared (Outcomes) then
         for I in 1 .. JSON.Length (Outcomes) loop
            declare
               Word   : constant String := JSON.Member_Key (Outcomes, I);
               Fields : constant JSON.Value :=
                 Outcome_Words.Data_Of (Outcomes, Word);
            begin
               if JSON.Kind_Of (Fields) = JSON.JSON_Object then
                  Append
                    (Lines,
                     "With " & Word & ", also put:" & LF
                     & Listed_Fields (Fields, ""));
               end if;
            end;
         end loop;
      end if;
      return To_String (Lines);
   end Data_Contract;

   --  The problems the step's previous answer was refused for, one line
   --  each and a blank line after; "" when there are none.
   function Refusal (Refused : Synapse.Core.Text_Lists.Vector) return String
   is
      Lines : Unbounded_String;
   begin
      if Refused.Is_Empty then
         return "";
      end if;
      Append (Lines, "Your last answer was refused:" & LF);
      for Problem of Refused loop
         Append (Lines, "- " & Problem & LF);
      end loop;
      return To_String (Lines) & LF;
   end Refusal;

   function Parts
     (Role            : String;
      Assignment      : String;
      Step            : String;
      Initial_Input   : JSON.Value;
      Previous_Output : JSON.Value;
      Outcomes        : JSON.Value := JSON.Null_Value;
      Interactive     : Boolean := False;
      Declared_Input  : JSON.Value := JSON.Null_Value;
      Data            : JSON.Value := JSON.Null_Value;
      Refused         : Synapse.Core.Text_Lists.Vector :=
        Synapse.Core.Text_Lists.Vectors.Empty_Vector)
      return Part_Vectors.Vector
   is
      Result   : Part_Vectors.Vector;
      Wanted   : constant String := Data_Contract (Outcomes, Data);
      Refusing : constant String := Refusal (Refused);

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
            Refusing
            & "When you are done, reply with one JSON object and nothing "
            & "else: no text before or after it and no code fence." & LF
            & "{""outcome"": ""<one of the outcomes below>"", ""summary"": "
            & """<text>"", ""data"": {}}" & LF
            & "`outcome` is exactly one of these words, the one that says "
            & "what actually happened:" & LF & Listed (Outcomes)
            & (if Wanted = "" then "" else LF & Wanted) & LF
            & "The pipeline decides which step runs next from it, so report "
            & "what is true, not what would be convenient. " & Tail);
      else
         Paragraph
           (Contract_Part,
            Refusing
            & "When you are done, reply with one JSON object and nothing "
            & "else: no text before or after it and no code fence." & LF
            & "{""outcome"": ""<one word>"", ""summary"": ""<text>"", "
            & """data"": {}}" & LF
            & "`outcome` is one word naming what actually happened, never "
            & "empty. The pipeline decides which step runs next from it, so "
            & "report what is true, not what would be convenient. " & Tail
            & (if Wanted = "" then ""
               else LF & LF & Wanted (Wanted'First .. Wanted'Last - 1)));
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
      Declared_Input  : JSON.Value := JSON.Null_Value;
      Data            : JSON.Value := JSON.Null_Value;
      Refused         : Synapse.Core.Text_Lists.Vector :=
        Synapse.Core.Text_Lists.Vectors.Empty_Vector) return String
   is
     (Text_Of
        (Parts
           (Role, Assignment, Step, Initial_Input, Previous_Output, Outcomes,
            Interactive, Declared_Input, Data, Refused)));

end Synapse.Pipeline.Prompts;
