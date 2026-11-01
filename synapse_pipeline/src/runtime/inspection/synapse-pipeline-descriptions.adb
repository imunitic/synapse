with Ada.Strings.Unbounded;

with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Permission_Levels;

package body Synapse.Pipeline.Descriptions is

   use Ada.Strings.Unbounded;
   use type Resolved.Instruction_Kind;

   package JSON renames Synapse.Core.JSON;

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
      elsif Item.Kind = Resolved.Prompt_Text then
         return JSON.Make_Object
           ([Member ("kind", JSON.Make_String ("prompt")),
             Member ("text", Text (Item.Text))]);
      end if;
      return JSON.Make_Object
        ([Member ("kind", JSON.Make_String ("skill")),
          Member ("name", Text (Item.Text))]);
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
                          when Resolved.Agent_Origin  => "agent")),
                  Member ("name", Text (O.Name)),
                  Member ("file", Text (O.File))]);
         end;
      end loop;
      return JSON.Make_Array (Result);
   end Origins_JSON;

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
            ("tools",
             (if Item.Tools.Found then Item.Tools.Value
              else JSON.Null_Value)),
          Member
            ("timeout_seconds",
             Count
               (if Item.Timeout_Seconds > 0 then Item.Timeout_Seconds
                else Settings.Default_Timeout_Seconds)),
          Member ("retries", Count (Item.Retries)),
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
