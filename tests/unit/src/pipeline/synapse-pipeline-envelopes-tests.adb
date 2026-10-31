with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Guards;

package body Synapse.Pipeline.Envelopes.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type JSON.Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   Sample : constant String :=
     "{""outcome"":""Changes_Requested"",""summary"":""Two problems."","
     & """data"":{""findings"":[""a"",""b""],""blocking"":true}}";

   function Value (Text : String) return JSON.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Parsed.Ok, "the sample is JSON: " & Text);
      return Parsed.Item;
   end Value;

   function Altered (Was, Now : String) return String is
      At_Index : constant Natural := Ada.Strings.Fixed.Index (Sample, Was);
   begin
      Assert (At_Index > 0, "'" & Was & "' is in the sample");
      return Sample (Sample'First .. At_Index - 1) & Now
        & Sample (At_Index + Was'Length .. Sample'Last);
   end Altered;

   --  Text must be refused, saying Message.
   procedure Assert_Refused (Text, Message, Label : String) is
      R : constant Envelope_Results.Result := Parse (Text);
   begin
      Assert (not Envelope_Results.Is_Success (R), Label & ": refused");
      if not Envelope_Results.Is_Success (R) then
         Assert
           (Ada.Strings.Fixed.Index
              (To_String (Envelope_Results.Error (R)), Message) > 0,
            Label & ": says '" & Message & "', says "
            & To_String (Envelope_Results.Error (R)));
      end if;
   end Assert_Refused;

   procedure A_Result_Is_Read_Into_Its_Three_Parts
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Envelope_Results.Result := Parse (Sample);
   begin
      Assert (Envelope_Results.Is_Success (R), "it is accepted");
      declare
         E : constant Envelope := Envelope_Results.Value (R);
      begin
         Assert
           (To_String (E.Outcome) = "Changes_Requested"
            and then To_String (E.Summary) = "Two problems.",
            "outcome and summary");
         Assert
           (JSON.Kind_Of (E.Data) = JSON.JSON_Object
            and then JSON.Length (JSON.Member_Value (E.Data, "findings")) = 2,
            "the data, as it was");
      end;
   end A_Result_Is_Read_Into_Its_Three_Parts;

   procedure The_Data_May_Be_Empty_But_Not_Absent
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Envelope_Results.Is_Success
           (Parse ("{""outcome"":""Done"",""summary"":"""",""data"":{}}")),
         "an empty summary and empty data are fine");
      Assert_Refused
        ("{""outcome"":""Done"",""summary"":""s""}", "'data' is missing",
         "no data");
   end The_Data_May_Be_Empty_But_Not_Absent;

   procedure A_Result_Survives_Being_Written_And_Read
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Original : constant Envelope_Results.Result := Parse (Sample);
      Item     : constant Envelope := Envelope_Results.Value (Original);
   begin
      Assert
        (Envelope_Results.Is_Success (From_JSON (To_JSON (Item)))
         and then Envelope_Results.Value (From_JSON (To_JSON (Item))) = Item,
         "as JSON");
      Assert
        (Envelope_Results.Is_Success (Parse (To_Text (Item)))
         and then Envelope_Results.Value (Parse (To_Text (Item))) = Item,
         "as text");
      Assert
        (To_Text (Item) = Sample,
         "written in the same order every time: " & To_Text (Item));
   end A_Result_Survives_Being_Written_And_Read;

   procedure A_Result_That_Is_Wrong_Is_Refused_Where
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Refused ("{""outcome"":", "result: not JSON", "not JSON");
      Assert_Refused ("[]", "result: expected an object", "a list");
      Assert_Refused ("""done""", "result: expected an object", "a string");
      Assert_Refused
        (Altered ("""outcome"":""Changes_Requested"",", ""),
         "'outcome' is missing", "no outcome");
      Assert_Refused
        (Altered ("""summary"":""Two problems."",", ""),
         "'summary' is missing", "no summary");
      Assert_Refused
        (Altered ("""Changes_Requested""", "3"), "outcome: expected a string",
         "a number outcome");
      Assert_Refused
        (Altered ("""Changes_Requested""", """"""),
         "outcome: must not be empty", "an empty outcome");
      Assert_Refused
        (Altered ("""Two problems.""", "null"), "summary: expected a string",
         "a null summary");
      Assert_Refused
        (Altered ("{""findings"":[""a"",""b""],""blocking"":true}", "[]"),
         "data: expected an object", "a list for the data");
      Assert_Refused
        (Altered ("{""findings"":[""a"",""b""],""blocking"":true}", "null"),
         "data: expected an object", "null data");
   end A_Result_That_Is_Wrong_Is_Refused_Where;

   procedure Another_Member_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert_Refused
        (Altered ("""data""", """secret"":1,""data"""),
         "'secret' is not allowed; a result has outcome, summary and data",
         "an extra member");
      Assert_Refused
        (Altered ("""blocking"":true}}", """blocking"":true},""extra"":null}"),
         "'extra' is not allowed", "an extra member at the end");
   end Another_Member_Is_Refused;

   --  The names in a JSON list of strings, in order, joined with spaces.
   function Names_In (List : JSON.Value) return String is
      Result : Unbounded_String;
   begin
      for I in 1 .. JSON.Length (List) loop
         Append (Result, JSON.As_String (JSON.Element (List, I)) & " ");
      end loop;
      return To_String (Result);
   end Names_In;

   function Keys_Of (Object : JSON.Value) return String is
      Result : Unbounded_String;
   begin
      for I in 1 .. JSON.Length (Object) loop
         Append (Result, JSON.Member_Key (Object, I) & " ");
      end loop;
      return To_String (Result);
   end Keys_Of;

   procedure The_Schema_Says_What_The_Checks_Accept
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Document : constant JSON.Value := Schema;
      Written  : constant JSON.Value :=
        To_JSON
          (Envelope'(Outcome => To_Unbounded_String ("o"), Summary =>
                       To_Unbounded_String ("s"), Data => <>));
   begin
      Assert
        (JSON.As_String (JSON.Member_Value (Document, "type")) = "object",
         "an object");
      Assert
        (JSON.Kind_Of (JSON.Member_Value (Document, "additionalProperties")) =
         JSON.JSON_Boolean
         and then not JSON.As_Boolean
                        (JSON.Member_Value (Document, "additionalProperties")),
         "and nothing else");
      Assert
        (Names_In (JSON.Member_Value (Document, "required")) =
         Keys_Of (Written),
         "it requires every member a result is written with: "
         & Names_In (JSON.Member_Value (Document, "required")));
      Assert
        (Keys_Of (JSON.Member_Value (Document, "properties")) =
         Keys_Of (Written),
         "and describes the same members");
      declare
         Properties : constant JSON.Value :=
           JSON.Member_Value (Document, "properties");
      begin
         Assert
           (JSON.As_String
              (JSON.Member_Value
                 (JSON.Member_Value (Properties, "data"), "type")) = "object",
            "data is an object");
         Assert
           (JSON.As_String
              (JSON.Member_Value
                 (JSON.Member_Value (Properties, "summary"), "type")) =
            "string",
            "summary is a string");
         Assert
           (JSON.As_Integer
              (JSON.Member_Value
                 (JSON.Member_Value (Properties, "outcome"), "minLength")) = 1,
            "an outcome is not empty");
      end;
   end The_Schema_Says_What_The_Checks_Accept;

   procedure A_Checked_Result_Can_Be_Judged_By_A_Guard
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Envelope_Results.Result := Parse (Sample);
      Guard : constant JSON.Value :=
        Value
          ("{""and"": [{""=="": [{""var"": ""outcome""}, "
           & """Changes_Requested""]}, {""var"": ""data.blocking""}]}");
   begin
      Assert (Envelope_Results.Is_Success (R), "the result is accepted");
      declare
         Held : constant Guards.Guard_Results.Result :=
           Guards.Holds (Guard, To_JSON (Envelope_Results.Value (R)));
      begin
         Assert
           (Guards.Guard_Results.Is_Success (Held)
            and then Guards.Guard_Results.Value (Held),
            "an accepted result is what a guard reads");
      end;
   end A_Checked_Result_Can_Be_Judged_By_A_Guard;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Envelopes");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Result_Is_Read_Into_Its_Three_Parts'Access,
         "A result is read into its three parts");
      Register_Routine
        (T, The_Data_May_Be_Empty_But_Not_Absent'Access,
         "The data may be empty but not absent");
      Register_Routine
        (T, A_Result_Survives_Being_Written_And_Read'Access,
         "A result survives being written and read");
      Register_Routine
        (T, A_Result_That_Is_Wrong_Is_Refused_Where'Access,
         "A result that is wrong is refused, saying where");
      Register_Routine
        (T, Another_Member_Is_Refused'Access, "Another member is refused");
      Register_Routine
        (T, The_Schema_Says_What_The_Checks_Accept'Access,
         "The schema says what the checks accept");
      Register_Routine
        (T, A_Checked_Result_Can_Be_Judged_By_A_Guard'Access,
         "A checked result can be judged by a guard");
   end Register_Tests;

end Synapse.Pipeline.Envelopes.Tests;
