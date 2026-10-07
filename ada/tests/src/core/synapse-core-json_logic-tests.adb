with Ada.Exceptions;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Interfaces;

with Synapse.Core.Glob;

package body Synapse.Core.JSON_Logic.Tests is

   use AUnit.Assertions;
   use JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  JSON text with ' standing for ", so tests stay readable.
   function Q (Text : String) return String is
      Result : String := Text;
   begin
      for C of Result loop
         if C = ''' then
            C := '"';
         end if;
      end loop;
      return Result;
   end Q;

   function Parsed (Text : String) return Value is
      R : constant Parse_Result := Parse (Q (Text));
   begin
      Assert (R.Ok, "test JSON must parse: " & Text);
      return R.Item;
   end Parsed;

   function Run (Rule : String; Data : String := "null") return Value
   is (Evaluate (Parsed (Rule), (Data => Parsed (Data), others => <>)));

   function Is_True (V : Value) return Boolean
   is (Kind_Of (V) = JSON_Boolean and then As_Boolean (V));

   function Is_False (V : Value) return Boolean
   is (Kind_Of (V) = JSON_Boolean and then not As_Boolean (V));

   procedure Raises_Invalid_Arguments (Rule : String) is
      Ignored : Value;
   begin
      Ignored := Run (Rule);
      Assert (False, "should raise Invalid_Arguments: " & Rule);
   exception
      when Invalid_Arguments =>
         null;
   end Raises_Invalid_Arguments;

   procedure Raises_Unknown_Operator (Rule : String; Ops : Operator_Set'Class)
   is
      Ignored : Value;
   begin
      Ignored :=
        Evaluate (Parsed (Rule), (Data => Null_Value, others => <>), Ops);
      Assert (False, "should raise Unknown_Operator: " & Rule);
   exception
      when Unknown_Operator =>
         null;
   end Raises_Unknown_Operator;

   ---------------------------------------------------------------------------
   --  var and the current item
   ---------------------------------------------------------------------------

   procedure A_Literal_Evaluates_To_Itself (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (As_Integer (Run ("42")) = 42, "an integer");
      Assert (As_String (Run ("'text'")) = "text", "a string");
      Assert (Kind_Of (Run ("[1, {'var': 'x'}]")) = JSON_Array,
              "an array is a literal even holding a rule");
      Assert (Kind_Of (Run ("{'a': 1, 'b': 2}")) = JSON_Object,
              "a multi-key object is a literal");
      Assert (Length (Run ("{}")) = 0, "an empty object is a literal");
   end A_Literal_Evaluates_To_Itself;

   procedure Var_Reads_A_Dotted_Path (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (As_String (Run ("{'var': 'frontmatter.status'}",
                              "{'frontmatter': {'status': 'TODO'}}"))
              = "TODO", "a nested value");
      Assert (As_String (Run ("{'var': ['frontmatter.missing', 'fallback']}",
                              "{'frontmatter': {}}"))
              = "fallback", "the default");
      Assert (Kind_Of (Run ("{'var': 'nope'}", "{}")) = JSON_Null,
              "null with no default");
      Assert (Kind_Of (Run ("{'var': 'a.b'}", "{'a': 5}")) = JSON_Null,
              "a step through a non-object misses");
      Assert (Kind_Of (Run ("{'var': 'a.0'}", "{'a': [7]}")) = JSON_Null,
              "an array is not indexed");
   end Var_Reads_A_Dotted_Path;

   procedure Var_Without_A_Path_Reads_The_Context
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Data : constant Value := Parsed ("{'frontmatter': {'tags': []}}");
      Item : constant Value := Parsed ("'synapse'");
      Rule : constant Value := Parsed ("{'var': ''}");
   begin
      Assert (As_String (Evaluate (Rule, (Data, Item, True))) = "synapse",
              "the current item when one is set");
      Assert (Evaluate (Rule, (Data => Data, others => <>)) = Data,
              "the data tree when none is");
      Assert (Evaluate (Parsed ("{'var': []}"), (Data => Data, others => <>))
              = Data, "no arguments at all");
      Assert (Evaluate (Parsed ("{'var': 5}"), (Data => Data, others => <>))
              = Data, "a path that is not a string");
   end Var_Without_A_Path_Reads_The_Context;

   procedure The_Outer_Data_Stays_Reachable (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant Value :=
        Parsed ("{'in': [{'var': ''}, {'var': 'vocabulary'}]}");
   begin
      Assert
        (Is_True
           (Evaluate
              (Rule,
                (Data     =>
                   Parsed ("{'vocabulary': ['synapse', 'vault-infra']}"),
                Item     => Parsed ("'synapse'"),
                Has_Item => True))),
         "the item is looked up in the outer data");
   end The_Outer_Data_Stays_Reachable;

   procedure A_Dot_In_A_Key_Splits_The_Path (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Kind_Of
           (Run ("{'var': 'vocabularies.synapse-tag-vocabulary.conf'}",
                  "{'vocabularies': {'synapse-tag-vocabulary.conf':"
                  & " ['synapse']}}"))
         = JSON_Null,
         "a dotted key is not reachable, so vocabularies are keyed by stem");
   end A_Dot_In_A_Key_Splits_The_Path;

   ---------------------------------------------------------------------------
   --  all
   ---------------------------------------------------------------------------

   procedure All_Tests_Every_Element (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_True (Run ("{'all': [[1, 2, 3], {'>': [{'var': ''}, 0]}]}")),
              "every element passes");
      Assert
        (Is_False (Run ("{'all': [[1, -2, 3], {'>': [{'var': ''}, 0]}]}")),
              "one fails");
      Assert (Is_True (Run ("{'all': [[], {'>': [{'var': ''}, 0]}]}")),
              "an empty array is vacuously true");
      Assert (Is_False
                (Run ("{'all': ['not-an-array', {'>': [{'var': ''}, 0]}]}")),
              "a non-array is false");
      Raises_Invalid_Arguments ("{'all': [[1]]}");
   end All_Tests_Every_Element;

   procedure All_Checks_Tags_Against_A_Vocabulary
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Rule  : constant String :=
        "{'all': [{'var': 'frontmatter.tags'},"
        & " {'in': [{'var': ''},"
        & " {'var': 'vocabularies.synapse-tag-vocabulary'}]}]}";
      Vocab : constant String :=
        "'vocabularies': {'synapse-tag-vocabulary':"
        & " ['synapse', 'vault-infra', 'architecture']}";
   begin
      Assert
        (Is_True
           (Run (Rule, "{'frontmatter': {'tags': ['synapse', 'vault-infra']}, "
                       & Vocab & "}")),
         "known tags");
      Assert
        (Is_False
           (Run (Rule, "{'frontmatter': {'tags': ['synapse', 'bogus-tag']}, "
                       & Vocab & "}")),
         "a tag outside the vocabulary");
   end All_Checks_Tags_Against_A_Vocabulary;

   ---------------------------------------------------------------------------
   --  Boolean operators
   ---------------------------------------------------------------------------

   procedure Xor_Is_True_For_Exactly_One (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_False (Run ("{'xor': [true, true]}")), "both");
      Assert (Is_True (Run ("{'xor': [true, false]}")), "one");
      Assert (Is_False (Run ("{'xor': [false, false]}")), "neither");
      Assert (Is_True (Run ("{'xor': [true, false, false]}")), "one of three");
      Assert (Is_False (Run ("{'xor': [true, true, true]}")),
              "three is odd but not exactly one");
   end Xor_Is_True_For_Exactly_One;

   procedure And_And_Or_Return_The_Deciding_Operand
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_False (Run ("{'and': [true, false, true]}")),
              "and stops at the first falsy value");
      Assert (As_Integer (Run ("{'and': [1, 2, 3]}")) = 3,
              "and returns the last value when all are truthy");
      Assert (Is_True (Run ("{'and': []}")), "and of nothing is true");
      Assert (As_String (Run ("{'or': [false, 0, 'found', 'unreached']}"))
              = "found", "or returns the first truthy value");
      Assert (Is_False (Run ("{'or': []}")), "or of nothing is false");
      --  A short-circuited operand is never evaluated.
      Assert (Is_False (Run ("{'and': [false, {'no_such_operator': 1}]}")),
              "and does not evaluate past a falsy operand");
      Assert (Is_True (Run ("{'or': [true, {'no_such_operator': 1}]}")),
              "or does not evaluate past a truthy operand");
   end And_And_Or_Return_The_Deciding_Operand;

   procedure Not_Negates_Truthiness (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_False (Run ("{'!': true}")), "bare value");
      Assert (Is_False (Run ("{'!': [true]}")), "argument list");
      Assert (Is_True (Run ("{'!': []}")), "no operand");
      Assert (Is_True (Run ("{'!': 0}")), "a falsy number");
   end Not_Negates_Truthiness;

   procedure Truthiness_Follows_JsonLogic (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Truthy (Make_Boolean (False)), "false");
      Assert (not Truthy (Make_Integer (0)), "0");
      Assert (not Truthy (Make_Float (0.0)), "0.0");
      Assert (not Truthy (Make_String ("")), "empty string");
      Assert (not Truthy (Null_Value), "null");
      Assert (not Truthy (Parsed ("[]")), "empty array");
      Assert (not Truthy (Make_Number_String ("0")), "number string zero");
      Assert (Truthy (Make_Integer (1)), "1");
      Assert (Truthy (Make_String ("x")), "non-empty string");
      Assert (Truthy (Parsed ("{}")), "an empty object is truthy");
      Assert (Truthy (Parsed ("[0]")), "a non-empty array");
      Assert (Truthy (Make_Number_String ("12345678901234567890")),
              "a big number string");
   end Truthiness_Follows_JsonLogic;

   ---------------------------------------------------------------------------
   --  Equality, membership, ordering
   ---------------------------------------------------------------------------

   procedure Equality_Compares_Evaluated_Values
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_True (Run ("{'==': [{'var': 'status'}, 'REVIEW']}",
                            "{'status': 'REVIEW'}")), "==");
      Assert (Is_True (Run ("{'!=': [1, 2]}")), "!=");
      Assert (Is_True (Run ("{'==': [1, 1.0]}")), "an integer equals a float");
      Assert
        (Is_True (Run ("{'==': [1, '1']}")),
         "a digit string equals a number");
      Assert (Is_False (Run ("{'==': [1, '1x']}")), "other strings do not");
      Assert (Is_False (Run ("{'==': ['1', '01']}")),
              "two strings compare as text");
      Assert
        (Is_True
           (Run ("{'==': [[1, {'a': 2, 'b': 3}], [1.0, {'b': 3, 'a': 2}]]}")),
              "arrays element by element, objects without member order");
      Assert (Is_False (Run ("{'==': [[1, 2], [1, 2, 3]]}")), "array lengths");
      Assert (Is_False (Run ("{'==': [null, false]}")), "null is not false");
      Assert (Is_True (Run ("{'==': [null, null]}")), "null equals null");
      Raises_Invalid_Arguments ("{'==': [1]}");
   end Equality_Compares_Evaluated_Values;

   procedure In_Tests_Membership_And_Containment
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Is_True (Run ("{'in': [{'var': 'status'}, ['TODO', 'IN-PROGRESS']]}",
                            "{'status': 'IN-PROGRESS'}")), "array membership");
      Assert (Is_False (Run ("{'in': ['DONE', ['TODO', 'IN-PROGRESS']]}")),
              "array absence");
      Assert (Is_True (Run ("{'in': ['log', 'catalog']}")), "substring");
      Assert (Is_True (Run ("{'in': ['', 'catalog']}")), "empty substring");
      Assert (Is_False (Run ("{'in': [5, 'catalog']}")),
              "a non-string needle in a string");
      Assert
        (Is_False (Run ("{'in': ['a', 5]}")),
         "a haystack of neither kind");
      Assert (Is_True (Run ("{'in': [2, [1, '2']]}")), "coerced membership");
      Raises_Invalid_Arguments ("{'in': ['x']}");
   end In_Tests_Membership_And_Containment;

   procedure Comparisons_Coerce_Digit_Strings_Only
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_True (Run ("{'<': [1, 2]}")), "<");
      Assert (Is_True (Run ("{'>=': [2, 2]}")), ">=");
      Assert (Is_True (Run ("{'<=': [2, 2.5]}")), "<= across kinds");
      Assert (Is_True (Run ("{'>': [3, 2]}")), ">");
      Assert (Is_True (Run ("{'<': [1, '2']}")), "a digit string coerces");
      Assert (Is_False (Run ("{'<': [1, '2px']}")), "other strings never do");
      Assert (Is_False (Run ("{'<': ['9', '10']}")),
              "two digit strings compare as text");
      Assert (Is_True (Run ("{'<': ['abc', 'abd']}")), "text order");
      Assert (Is_False (Run ("{'<': [null, 1]}")), "null is not a number");
      Assert
        (Is_False (Run ("{'<': [1, true]}")),
         "a boolean is not a number");
      Assert (Is_False (Run ("{'<': ['', 1]}")), "an empty string is not 0");
      Raises_Invalid_Arguments ("{'<': [1]}");
   end Comparisons_Coerce_Digit_Strings_Only;

   ---------------------------------------------------------------------------
   --  glob, regexp, starts_with
   ---------------------------------------------------------------------------

   procedure Glob_Matches_A_Path (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant String := "{'glob': ['designs/*', {'var': 'path'}]}";
   begin
      Assert (Is_True (Run (Rule, "{'path': 'designs/synapse/sb-001.md'}")),
              "a path below the prefix");
      Assert (Is_False (Run (Rule, "{'path': 'tasks/synapse/sb-001.md'}")),
              "a path outside it");
      Assert (Is_False (Run ("{'glob': [1, 'a']}")), "a non-string pattern");
      Assert (Is_False (Run ("{'glob': ['a', null]}")), "a non-string text");
   end Glob_Matches_A_Path;

   procedure Glob_Match_Edge_Cases (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      use Synapse.Core.Glob;
   begin
      Assert (not Glob_Match ("", "anything"), "an empty pattern, some text");
      Assert (Glob_Match ("", ""), "an empty pattern, empty text");
      Assert (Glob_Match ("*", ""), "a lone star matches nothing too");
      Assert (Glob_Match ("*", "anything"), "a lone star matches anything");
      Assert (Glob_Match ("**", "x"), "consecutive stars");
      Assert (Glob_Match ("a*", "a"), "trailing star, empty run");
      Assert (Glob_Match ("a*", "abc"), "trailing star");
      Assert (not Glob_Match ("a*", "ba"), "the first segment is a prefix");
      Assert (Glob_Match ("*c", "abc"), "leading star");
      Assert (not Glob_Match ("*c", "abcd"), "the last segment ends the text");
      Assert (Glob_Match ("a*c", "abxc"), "star in the middle");
      Assert (Glob_Match ("a*b*c", "aXbYc"), "two stars");
      Assert (Glob_Match ("a*a", "aXa"), "same segment twice");
      Assert (not Glob_Match ("a*a", "a"), "segments may not overlap");
      Assert (not Glob_Match ("ab*bc", "abc"), "overlap through a star");
      Assert (Glob_Match ("ab*bc", "abbc"), "touching but not overlapping");
      Assert (Glob_Match ("*ab*ab", "abab"), "repeated middle segments");
      Assert (not Glob_Match ("*ab*ab", "ab"), "but needs both");
      Assert
        (Glob_Match ("a*b", "abXb"),
         "the last segment may be a later one");
      Assert (Glob_Match ("abc", "abc"), "no star, equal");
      Assert (not Glob_Match ("abc", "abcd"), "no star, longer text");
      Assert (not Glob_Match ("abcd", "abc"), "no star, longer pattern");
      Assert (Glob_Match ("designs/*", "designs/"), "empty run after a slash");
   end Glob_Match_Edge_Cases;

   procedure Regexp_Searches_The_Content (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Is_True (Run ("{'regexp': ['## Status\nReady', {'var': 'content'}]}",
                            "{'content': '# Title\n\n## Status\nReady\n'}")),
              "a literal substring across lines");
      Assert
        (Is_False (Run ("{'regexp': ['^Ready', 'Not ready']}")),
         "anchored");
      Assert (Is_False (Run ("{'regexp': [1, 'a']}")), "a non-string pattern");
   end Regexp_Searches_The_Content;

   procedure Regexp_Reports_A_Pattern_That_Gives_Up
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Ignored : Value;
   begin
      Ignored :=
        Run ("{'regexp': ['a*a*a*a*a*a*b', '"
             & String'(1 .. 40 => 'a') & "']}");
      Assert (False, "should raise Pattern_Too_Complex");
   exception
      when E : Pattern_Too_Complex =>
         Assert (Ada.Exceptions.Exception_Message (E) = "a*a*a*a*a*a*b",
                 "the message names the pattern");
   end Regexp_Reports_A_Pattern_That_Gives_Up;

   procedure Starts_With_Checks_A_Prefix (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Rule : constant String :=
        "{'starts_with': [{'var': 'title'}, {'var': 'id'}]}";
   begin
      Assert
        (Is_True
           (Run (Rule, "{'title': 'sb-102 -- Something', 'id': 'sb-102'}")),
              "a prefix");
      Assert (Is_False (Run (Rule, "{'title': 'Something', 'id': 'sb-102'}")),
              "not a prefix");
      Assert (Is_True (Run ("{'starts_with': ['anything', '']}")),
              "an empty prefix");
      Assert (Is_False (Run ("{'starts_with': ['ab', 'abc']}")),
              "a prefix longer than the text");
      Assert
        (Is_False (Run ("{'starts_with': [123, '1']}")),
         "a non-string value");
      Assert (Is_False (Run ("{'starts_with': ['123', null]}")),
              "a non-string prefix");
      Raises_Invalid_Arguments ("{'starts_with': ['only-one']}");
   end Starts_With_Checks_A_Prefix;

   procedure A_Compound_Rule_Matches (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Is_True
           (Run ("{'and': [{'glob': ['designs/*', {'var': 'path'}]},"
                 & " {'regexp': ['## Status\nDiscussing',"
                 & " {'var': 'content'}]}]}",
                 "{'path': 'designs/synapse/sb-001.md',"
                 & " 'content': '# Title\n\n## Status\nDiscussing\n'}")),
         "the vault's own synapse-status shape");
   end A_Compound_Rule_Matches;

   ---------------------------------------------------------------------------
   --  Operators and errors
   ---------------------------------------------------------------------------

   procedure An_Unknown_Operator_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Raises_Unknown_Operator ("{'whatever': [1, 2]}", No_Operators);
      Raises_Unknown_Operator ("{'is_positive': 1}", No_Operators);
      begin
         declare
            Ignored : constant Value := Run ("{'whatever': [1, 2]}");
         begin
            null;
         end;
      exception
         when E : Unknown_Operator =>
            Assert (Ada.Exceptions.Exception_Message (E) = "whatever",
                    "the message is the operator name");
      end;
   end An_Unknown_Operator_Raises;

   procedure Built_In_Names_Match_The_Dispatch (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      for I in 1 .. Built_In_Count loop
         declare
            Name : constant String := Built_In_Name (I);
         begin
            Assert (Is_Built_In (Name), Name & " is listed");
            begin
               declare
                  Ignored : constant Value :=
                    Run ("{'" & Name & "': [1]}");
               begin
                  null;
               end;
            exception
               when Invalid_Arguments =>
                  null;
               when Unknown_Operator =>
                  Assert (False, Name & " is listed but not dispatched");
            end;
         end;
      end loop;
      Assert (not Is_Built_In ("whatever"), "an unlisted name");
      Assert (not Is_Built_In (""), "the empty name");
   end Built_In_Names_Match_The_Dispatch;

   type Positive_Set is new Operator_Set with null record;

   overriding
   function Has_Operator (Set : Positive_Set; Name : String) return Boolean;

   overriding
   function Apply
     (Set   : Positive_Set;
      Name  : String;
      Args  : Value_Array;
      Where : Scope) return Value;

   overriding
   function Has_Operator (Set : Positive_Set; Name : String) return Boolean
   is (Name = "is_positive");

   overriding
   function Apply
     (Set   : Positive_Set;
      Name  : String;
      Args  : Value_Array;
      Where : Scope) return Value
   is
   begin
      if Args'Length < 1 then
         raise Invalid_Arguments with Name;
      end if;
      --  Evaluating the operand calls back into the evaluator with this set.
      declare
         V : constant Value := Evaluate (Args (Args'First), Where, Set);
      begin
         return
           Make_Boolean
             ((Kind_Of (V) = JSON_Integer and then As_Integer (V) > 0)
              or else (Kind_Of (V) = JSON_Float and then As_Float (V) > 0.0));
      end;
   end Apply;

   procedure A_Custom_Operator_Resolves (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Ops : constant Positive_Set := (null record);

      function Check (Rule, Data : String) return Value
      is (Evaluate
            (Parsed (Rule), (Data => Parsed (Data), others => <>), Ops));
   begin
      Assert (Is_True (Check ("{'is_positive': {'var': 'n'}}", "{'n': 5}")),
              "an extra operator");
      Assert (Is_False (Check ("{'is_positive': {'var': 'n'}}", "{'n': -5}")),
              "and its other answer");
      Assert (Is_True (Check ("{'and': [{'is_positive': {'var': 'n'}},"
                              & " {'<': [{'var': 'n'}, 10]}]}", "{'n': 5}")),
              "composed with a built-in");
      Assert (Is_True (Check ("{'<': [{'var': 'n'}, 10]}", "{'n': 5}")),
              "built-ins still work with an extra set");
      Assert
        (Is_True (Check ("{'all': [[1, 2], {'is_positive': {'var': ''}}]}",
                              "null")),
              "an extra operator inside all sees the current item");
      Raises_Unknown_Operator ("{'whatever_else': 1}", Ops);
   end A_Custom_Operator_Resolves;

   ---------------------------------------------------------------------------
   --  Properties
   ---------------------------------------------------------------------------

   Seed : Interfaces.Unsigned_64 := 20_261_010;

   function Next (Limit : Positive) return Natural is
      use type Interfaces.Unsigned_64;
   begin
      Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural ((Seed / 2**20) mod Interfaces.Unsigned_64 (Limit));
   end Next;

   function Random_Data (Depth : Natural) return Value is
   begin
      case Next (if Depth >= 3 then 6 else 8) is
         when 0 =>
            return Null_Value;

         when 1 =>
            return Make_Boolean (Next (2) = 1);

         when 2 =>
            return Make_Integer (Long_Long_Integer (Next (20)) - 10);

         when 3 =>
            return Make_Float (Long_Float (Next (20)) - 10.0 + 0.5);

         when 4 =>
            return Make_String (Natural'Image (Next (12)) (2 .. 2));

         when 5 =>
            return Make_String ("k" & Natural'Image (Next (3)) (2 .. 2));

         when 6 =>
            declare
               Items : Value_Array (1 .. Next (4));
            begin
               for I in Items'Range loop
                  Items (I) := Random_Data (Depth + 1);
               end loop;
               return Make_Array (Items);
            end;

         when others =>
            --  Empty, or two or more keys: a single-key object is a rule.
            declare
               Count  : constant Natural :=
                 (if Next (3) = 0 then 0 else 2 + Next (2));
               Fields : Member_Array (1 .. Count);
            begin
               for I in Fields'Range loop
                  Fields (I) :=
                    (Ada.Strings.Unbounded.To_Unbounded_String
                       ("k" & Natural'Image (I) (2 .. 2)),
                     Random_Data (Depth + 1));
               end loop;
               return Make_Object (Fields);
            end;
      end case;
   end Random_Data;

   function Pair (Operator : String; A, B : Value) return Value
   is (Make_Object
         ([(Ada.Strings.Unbounded.To_Unbounded_String (Operator),
            Make_Array ([A, B]))]));

   procedure Equality_Is_Reflexive_And_Symmetric
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Where : constant Scope := (Data => Null_Value, others => <>);
   begin
      for I in 1 .. 3_000 loop
         declare
            A : constant Value := Random_Data (0);
            B : constant Value := Random_Data (0);
         begin
            if not Loosely_Equal (A, A) then
               Assert (False, "case" & I'Image & ": not reflexive: "
                       & To_String (A));
            end if;
            pragma Warnings (Off, "*wrong order*");
            if Loosely_Equal (A, B) /= Loosely_Equal (B, A) then
               Assert (False, "case" & I'Image & ": not symmetric: "
                       & To_String (A) & " and " & To_String (B));
            end if;
            pragma Warnings (On, "*wrong order*");
            if Is_True (Evaluate (Pair ("==", A, B), Where))
              = Is_True (Evaluate (Pair ("!=", A, B), Where))
            then
               Assert (False, "case" & I'Image & ": != is not the negation");
            end if;
         end;
      end loop;
   end Equality_Is_Reflexive_And_Symmetric;

   procedure Boolean_Operators_Follow_Their_Definitions
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Where : constant Scope := (Data => Null_Value, others => <>);
   begin
      for I in 1 .. 3_000 loop
         declare
            A : constant Value := Random_Data (0);
            B : constant Value := Random_Data (0);
            And_Result : constant Value :=
              Evaluate (Pair ("and", A, B), Where);
            Or_Result  : constant Value := Evaluate (Pair ("or", A, B), Where);
            Xor_Result : constant Value :=
              Evaluate (Pair ("xor", A, B), Where);
         begin
            if Truthy (And_Result) /= (Truthy (A) and then Truthy (B)) then
               Assert (False, "case" & I'Image & ": and");
            end if;
            if Truthy (Or_Result) /= (Truthy (A) or else Truthy (B)) then
               Assert (False, "case" & I'Image & ": or");
            end if;
            if Is_True (Xor_Result) /= (Truthy (A) /= Truthy (B)) then
               Assert (False, "case" & I'Image & ": xor");
            end if;
            if And_Result /= (if Truthy (A) then B else A) then
               Assert
                 (False,
                  "case" & I'Image & ": and returns the wrong operand");
            end if;
            if Or_Result /= (if Truthy (A) then A else B) then
               Assert
                 (False,
                  "case" & I'Image & ": or returns the wrong operand");
            end if;
         end;
      end loop;
   end Boolean_Operators_Follow_Their_Definitions;

   procedure Evaluation_Never_Raises_On_Well_Formed_Rules
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      function Name_Of (Choice : Positive) return String
      is (case Choice is
            when 1 => "==",
            when 2 => "!=",
            when 3 => "<",
            when 4 => "in",
            when 5 => "and",
            when 6 => "or",
            when 7 => "xor",
            when 8 => "starts_with",
            when others => "all");
   begin
      for I in 1 .. 4_000 loop
         declare
            Data : constant Value := Random_Data (0);
            Rule : constant Value :=
              Pair (Name_Of (1 + Next (9)), Random_Data (1), Random_Data (1));
         begin
            declare
               Ignored : constant Value :=
                 Evaluate (Rule, (Data => Data, others => <>));
            begin
               null;
            end;
         exception
            when E : others =>
               Assert (False, "case" & I'Image & ": " & To_String (Rule)
                       & " raised " & Ada.Exceptions.Exception_Name (E));
         end;
      end loop;
   end Evaluation_Never_Raises_On_Well_Formed_Rules;

   procedure A_Parsed_Rule_Equals_A_Built_Rule (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Built : constant Value :=
        Pair ("==", Make_Integer (1),
              Make_Array ([Make_Integer (1)]));
      Where : constant Scope := (Data => Null_Value, others => <>);
   begin
      Assert (Evaluate (Parsed ("{'==': [1, [1]]}"), Where)
              = Evaluate (Built, Where), "same result either way");
      Assert (Parsed ("{'==': [1, [1]]}") = Built, "and the same value");
   end A_Parsed_Rule_Equals_A_Built_Rule;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.JSON_Logic");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Literal_Evaluates_To_Itself'Access,
         "A literal evaluates to itself");
      Register_Routine
        (T, Var_Reads_A_Dotted_Path'Access, "var reads a dotted path");
      Register_Routine
        (T, Var_Without_A_Path_Reads_The_Context'Access,
         "var without a path reads the context");
      Register_Routine
        (T, The_Outer_Data_Stays_Reachable'Access,
         "The outer data stays reachable");
      Register_Routine
        (T, A_Dot_In_A_Key_Splits_The_Path'Access,
         "A dot in a key splits the path");
      Register_Routine
        (T, All_Tests_Every_Element'Access, "all tests every element");
      Register_Routine
        (T, All_Checks_Tags_Against_A_Vocabulary'Access,
         "all checks tags against a vocabulary");
      Register_Routine
        (T, Xor_Is_True_For_Exactly_One'Access, "xor is true for exactly one");
      Register_Routine
        (T, And_And_Or_Return_The_Deciding_Operand'Access,
         "and and or return the deciding operand");
      Register_Routine
        (T, Not_Negates_Truthiness'Access, "! negates truthiness");
      Register_Routine
        (T, Truthiness_Follows_JsonLogic'Access,
         "Truthiness follows JsonLogic");
      Register_Routine
        (T, Equality_Compares_Evaluated_Values'Access,
         "Equality compares evaluated values");
      Register_Routine
        (T, In_Tests_Membership_And_Containment'Access,
         "in tests membership and containment");
      Register_Routine
        (T, Comparisons_Coerce_Digit_Strings_Only'Access,
         "Comparisons coerce digit strings only");
      Register_Routine
        (T, Glob_Matches_A_Path'Access, "glob matches a path");
      Register_Routine
        (T, Glob_Match_Edge_Cases'Access, "Glob_Match edge cases");
      Register_Routine
        (T, Regexp_Searches_The_Content'Access, "regexp searches the content");
      Register_Routine
        (T, Regexp_Reports_A_Pattern_That_Gives_Up'Access,
         "regexp reports a pattern that gives up");
      Register_Routine
        (T, Starts_With_Checks_A_Prefix'Access, "starts_with checks a prefix");
      Register_Routine
        (T, A_Compound_Rule_Matches'Access, "A compound rule matches");
      Register_Routine
        (T, An_Unknown_Operator_Raises'Access, "An unknown operator raises");
      Register_Routine
        (T, Built_In_Names_Match_The_Dispatch'Access,
         "Built-in names match the dispatch");
      Register_Routine
        (T, A_Custom_Operator_Resolves'Access, "A custom operator resolves");
      Register_Routine
        (T, Equality_Is_Reflexive_And_Symmetric'Access,
         "Equality is reflexive and symmetric");
      Register_Routine
        (T, Boolean_Operators_Follow_Their_Definitions'Access,
         "Boolean operators follow their definitions");
      Register_Routine
        (T, Evaluation_Never_Raises_On_Well_Formed_Rules'Access,
         "Evaluation never raises on well-formed rules");
      Register_Routine
        (T, A_Parsed_Rule_Equals_A_Built_Rule'Access,
         "A parsed rule equals a built rule");
   end Register_Tests;

end Synapse.Core.JSON_Logic.Tests;
