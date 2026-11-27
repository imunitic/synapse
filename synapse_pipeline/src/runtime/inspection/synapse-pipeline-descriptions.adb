with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Inputs;
with Synapse.Pipeline.Permission_Levels;

package body Synapse.Pipeline.Descriptions is

   use Ada.Strings.Unbounded;

   package JSON renames Synapse.Core.JSON;

   use type JSON.Kind;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function Text (Item : Unbounded_String) return JSON.Value is
     (JSON.Make_String (To_String (Item)));

   function Count (Item : Natural) return JSON.Value is
     (JSON.Make_Integer (Long_Long_Integer (Item)));

   function Instruction_JSON (Item : Resolved.Instruction) return JSON.Value is
   begin
      if not Item.Present then
         return JSON.Null_Value;
      end if;
      return JSON.Make_Object
        ([Member ("kind", JSON.Make_String ("prompt")),
          Member ("text", Text (Item.Text))]);
   end Instruction_JSON;

   function Origins_JSON (Items : Resolved.Origin_Vectors.Vector)
      return JSON.Value
   is
      Result : JSON.Value_Array (1 .. Natural (Items.Length));
   begin
      for I in Result'Range loop
         declare
            O : constant Resolved.Origin := Items (I);
         begin
            Result (I) :=
              JSON.Make_Object
                ([Member
                    ("kind",
                     JSON.Make_String
                       (case O.Kind is
                          when Resolved.System_Origin => "system",
                          when Resolved.Agent_Origin  => "agent",
                          when Resolved.Prompt_Origin => "prompt")),
                  Member ("name", Text (O.Name)),
                  Member ("file", Text (O.File))]);
         end;
      end loop;
      return JSON.Make_Array (Result);
   end Origins_JSON;

   --  The outcomes a step declares, each as its word and meaning; null when it
   --  declares none.
   function Outcomes_JSON (Declared : JSON.Value) return JSON.Value is
   begin
      if JSON.Kind_Of (Declared) /= JSON.JSON_Object then
         return JSON.Null_Value;
      end if;
      declare
         Items : JSON.Value_Array (1 .. JSON.Length (Declared));
      begin
         for I in Items'Range loop
            Items (I) :=
              JSON.Make_Object
                ([Member
                    ("word", JSON.Make_String (JSON.Member_Key (Declared, I))),
                  Member ("meaning", JSON.Member_At (Declared, I))]);
         end loop;
         return JSON.Make_Array (Items);
      end;
   end Outcomes_JSON;

   function Step_JSON
     (Item : Resolved.Step; Settings : Configs.Config) return JSON.Value
   is
     (JSON.Make_Object
        ([Member ("name", Text (Item.Name)),
          Member
            ("harness", JSON.Make_String (Harnesses.Name_Of (Item.Harness))),
          Member
            ("model",
             (if Item.Model.Found then Text (Item.Model.Value)
              else JSON.Null_Value)),
          Member
            ("permissions",
             (if Item.Permissions.Found then Text (Item.Permissions.Value)
              else JSON.Make_String
                     (Permission_Levels.Name_Of (Permission_Levels.Default)))),
          Member
            ("timeout_seconds",
             Count
               (if Item.Timeout_Seconds > 0 then Item.Timeout_Seconds
                else Settings.Default_Timeout_Seconds)),
          Member ("retries", Count (Item.Retries)),
          Member ("outcomes", Outcomes_JSON (Item.Outcomes)),
          Member ("role", Instruction_JSON (Item.Role)),
          Member ("assignment", Instruction_JSON (Item.Assignment)),
          Member ("origins", Origins_JSON (Item.Origins))]));

   function Edge_JSON (Index : Natural; Item : Resolved.Edge) return JSON.Value
   is
     (JSON.Make_Object
        ([Member ("index", Count (Index)),
          Member ("from", Text (Item.From)),
          Member ("to", Text (Item.To)),
          Member
            ("guard",
             (if Item.Has_Guard then Item.Guard else JSON.Null_Value)),
          Member
            ("max_iterations",
             (if Item.Max_Iterations > 0 then Count (Item.Max_Iterations)
              else JSON.Null_Value))]));

   function Member_Or_Null (Item : JSON.Value; Key : String) return JSON.Value
   is
     (if JSON.Kind_Of (Item) = JSON.JSON_Object
        and then JSON.Has_Member (Item, Key)
      then JSON.Member_Value (Item, Key)
      else JSON.Null_Value);

   --  The fields of a declaration's `fields` mapping, in declared order, each
   --  as an object with its name and its rules; a rule that is not written is
   --  left out, except `required`, which is then false.
   function Fields_JSON (Fields : JSON.Value) return JSON.Value is
      Count : constant Natural :=
        (if JSON.Kind_Of (Fields) = JSON.JSON_Object
         then JSON.Length (Fields) else 0);
      Items : JSON.Value_Array (1 .. Count);
   begin
      for I in Items'Range loop
         declare
            Rule     : constant JSON.Value := JSON.Member_At (Fields, I);
            Required : constant JSON.Value :=
              Member_Or_Null (Rule, "required");
            Members  : JSON.Member_Array (1 .. 9);
            Last     : Natural := 0;

            procedure Add (Key : String; Item : JSON.Value) is
            begin
               Last := Last + 1;
               Members (Last) := Member (Key, Item);
            end Add;

            procedure Add_If_Written (Key : String) is
            begin
               if JSON.Has_Member (Rule, Key) then
                  Add (Key, JSON.Member_Value (Rule, Key));
               end if;
            end Add_If_Written;
         begin
            Add ("name", JSON.Make_String (JSON.Member_Key (Fields, I)));
            Add ("type", Member_Or_Null (Rule, "type"));
            Add
              ("required",
               JSON.Make_Boolean
                 (JSON.Kind_Of (Required) = JSON.JSON_Boolean
                  and then JSON.As_Boolean (Required)));
            Add ("description", Member_Or_Null (Rule, "description"));
            Add_If_Written ("min_length");
            Add_If_Written ("const");
            Add_If_Written ("pattern");
            Add_If_Written ("enum");
            if JSON.Has_Member (Rule, "items") then
               declare
                  Of_Items : constant JSON.Value :=
                    JSON.Member_Value (Rule, "items");
               begin
                  Add
                    ("items",
                     (if JSON.Kind_Of (Of_Items) = JSON.JSON_Object
                      then JSON.Make_Object
                             ([Member
                                 ("fields",
                                  Fields_JSON
                                    (Member_Or_Null (Of_Items, "fields")))])
                      else Of_Items));
               end;
            end if;
            Items (I) := JSON.Make_Object (Members (1 .. Last));
         end;
      end loop;
      return JSON.Make_Array (Items);
   end Fields_JSON;

   --  The pipeline's `Input` declaration, or null when it declares none.
   function Input_JSON (Declared : JSON.Value) return JSON.Value is
   begin
      if JSON.Kind_Of (Declared) = JSON.JSON_Null then
         return JSON.Null_Value;
      end if;
      declare
         Checks     : constant JSON.Value :=
           Member_Or_Null (Declared, "checks");
         Text_Field : constant Synapse.Core.Optional_Text.Option :=
           Inputs.Single_Text_Field (Declared);
      begin
         return JSON.Make_Object
           ([Member ("fields",
                     Fields_JSON (Member_Or_Null (Declared, "fields"))),
             Member
               ("checks",
                (if JSON.Kind_Of (Checks) = JSON.JSON_Array then Checks
                 else JSON.Make_Array ([]))),
             Member
               ("single_text_field",
                (if Text_Field.Found then Text (Text_Field.Value)
                 else JSON.Null_Value))]);
      end;
   end Input_JSON;

   function Runner_Name (Kind : Configs.Runner_Kind) return String is
     (case Kind is
        when Configs.Process_Runner  => "process",
        when Configs.Scripted_Runner => "scripted");

   function Describe
     (Pipeline : Resolved.Pipeline; Settings : Configs.Config)
      return JSON.Value
   is
      Steps : JSON.Value_Array (1 .. Natural (Pipeline.Steps.Length));
      Edges : JSON.Value_Array (1 .. Natural (Pipeline.Edges.Length));
   begin
      for I in Steps'Range loop
         Steps (I) := Step_JSON (Pipeline.Steps (I), Settings);
      end loop;
      for I in Edges'Range loop
         Edges (I) := Edge_JSON (I - 1, Pipeline.Edges (I));
      end loop;
      return JSON.Make_Object
        ([Member ("format", JSON.Make_String (Format)),
          Member ("name", Text (Pipeline.Name)),
          Member ("input", Input_JSON (Pipeline.Input)),
          Member ("steps", JSON.Make_Array (Steps)),
          Member ("edges", JSON.Make_Array (Edges)),
          Member
            ("limits",
             JSON.Make_Object
               ([Member
                   ("default_timeout_seconds",
                    Count (Settings.Default_Timeout_Seconds)),
                 Member ("step_ceiling", Count (Settings.Step_Ceiling)),
                 Member
                   ("runner",
                    JSON.Make_String (Runner_Name (Settings.Runner)))]))]);
   end Describe;

end Synapse.Pipeline.Descriptions;
