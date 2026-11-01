package body Synapse.Pipeline.Envelopes is

   use Ada.Strings.Unbounded;
   use type JSON.Kind;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function To_JSON (Item : Envelope) return JSON.Value is
     (JSON.Make_Object
        ([Member ("outcome", JSON.Make_String (To_String (Item.Outcome))),
          Member ("summary", JSON.Make_String (To_String (Item.Summary))),
          Member ("data", Item.Data)]));

   function To_Text (Item : Envelope) return String is
     (JSON.To_String (To_JSON (Item)));

   function Schema return JSON.Value is
      function Typed (Name : String) return JSON.Value is
        (JSON.Make_Object ([Member ("type", JSON.Make_String (Name))]));
   begin
      return JSON.Make_Object
        ([Member ("type", JSON.Make_String ("object")),
          Member
            ("properties",
             JSON.Make_Object
               ([Member
                   ("outcome",
                    JSON.Make_Object
                      ([Member ("type", JSON.Make_String ("string")),
                        Member ("minLength", JSON.Make_Integer (1))])),
                 Member ("summary", Typed ("string")),
                 Member ("data", Typed ("object"))])),
          Member
            ("required",
             JSON.Make_Array
               ([JSON.Make_String ("outcome"), JSON.Make_String ("summary"),
                 JSON.Make_String ("data")])),
          Member ("additionalProperties", JSON.Make_Boolean (False))]);
   end Schema;

   function From_JSON
     (Document : JSON.Value) return Envelope_Results.Result
   is
      function Fail (Where, What : String) return Envelope_Results.Result is
        (Envelope_Results.Failure
           (To_Unbounded_String (Where & ": " & What)));

      Result : Envelope;
   begin
      if JSON.Kind_Of (Document) /= JSON.JSON_Object then
         return Fail ("result", "expected an object");
      end if;
      for I in 1 .. JSON.Length (Document) loop
         declare
            Key : constant String := JSON.Member_Key (Document, I);
         begin
            if Key not in "outcome" | "summary" | "data" then
               return Fail
                 ("result",
                  "'" & Key & "' is not allowed; a result has outcome, "
                  & "summary and data, and nothing else");
            end if;
         end;
      end loop;
      for Key in 1 .. 3 loop
         declare
            Name : constant String :=
              (case Key is
                 when 1      => "outcome",
                 when 2      => "summary",
                 when others => "data");
         begin
            if not JSON.Has_Member (Document, Name) then
               return Fail ("result", "'" & Name & "' is missing");
            end if;
         end;
      end loop;
      declare
         Outcome : constant JSON.Value :=
           JSON.Member_Value (Document, "outcome");
         Summary : constant JSON.Value :=
           JSON.Member_Value (Document, "summary");
         Data    : constant JSON.Value := JSON.Member_Value (Document, "data");
      begin
         if JSON.Kind_Of (Outcome) /= JSON.JSON_String then
            return Fail ("outcome", "expected a string");
         elsif JSON.As_String (Outcome) = "" then
            return Fail ("outcome", "must not be empty");
         elsif JSON.Kind_Of (Summary) /= JSON.JSON_String then
            return Fail ("summary", "expected a string");
         elsif JSON.Kind_Of (Data) /= JSON.JSON_Object then
            return Fail ("data", "expected an object");
         end if;
         Result.Outcome := To_Unbounded_String (JSON.As_String (Outcome));
         Result.Summary := To_Unbounded_String (JSON.As_String (Summary));
         Result.Data := Data;
      end;
      return Envelope_Results.Success (Result);
   end From_JSON;

   function Parse (Text : String) return Envelope_Results.Result is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      if not Parsed.Ok then
         return Envelope_Results.Failure
           (To_Unbounded_String
              ("result: not JSON: "
               & JSON.Parse_Error_Kind'Image (Parsed.Error) & " at byte"
               & Natural'Image (Parsed.Offset)));
      end if;
      return From_JSON (Parsed.Item);
   end Parse;

end Synapse.Pipeline.Envelopes;
