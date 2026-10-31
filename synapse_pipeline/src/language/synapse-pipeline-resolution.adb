with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Durations;
with Synapse.Pipeline.Syntax;

package body Synapse.Pipeline.Resolution is

   use Ada.Strings.Unbounded;
   use type Syntax.Definition_Kind;
   use type Syntax.Value_Kind;
   use type Syntax.Attribute_Vectors.Cursor;

   package JSON renames Synapse.Core.JSON;

   function Find
     (List : Syntax.Attribute_Vectors.Vector; Name : String)
      return Syntax.Attribute_Vectors.Cursor
   is
   begin
      for C in List.Iterate loop
         if To_String (Syntax.Attribute_Vectors.Element (C).Name.Name) = Name
         then
            return C;
         end if;
      end loop;
      return Syntax.Attribute_Vectors.No_Element;
   end Find;

   function Has (List : Syntax.Attribute_Vectors.Vector; Name : String)
      return Boolean is
     (Find (List, Name) /= Syntax.Attribute_Vectors.No_Element);

   --  The text of a name or a string value.
   function Text_Of (Item : Syntax.Value) return String is
     (case Item.Kind is
        when Syntax.Name_Value   => To_String (Item.Name),
        when Syntax.String_Value => To_String (Item.Text),
        when others              => "");

   --  The instructions a list of attributes gives: its prompt, else its skill.
   function Instruction_Of (List : Syntax.Attribute_Vectors.Vector)
      return Resolved.Instruction
   is
      Prompt : constant Syntax.Attribute_Vectors.Cursor :=
        Find (List, "Prompt");
      Skill  : constant Syntax.Attribute_Vectors.Cursor :=
        Find (List, "Skill");
   begin
      if Prompt /= Syntax.Attribute_Vectors.No_Element then
         return (Present => True, Kind => Resolved.Prompt_Text,
                 Text => Syntax.Attribute_Vectors.Element (Prompt).Item.Text);
      elsif Skill /= Syntax.Attribute_Vectors.No_Element then
         return (Present => True, Kind => Resolved.Skill_Name,
                 Text => Syntax.Attribute_Vectors.Element (Skill).Item.Text);
      end if;
      return (Present => False);
   end Instruction_Of;

   --  `outcome == Name`, as JsonLogic.
   function Outcome_Test (Name : String) return JSON.Value is
      Variable : constant JSON.Value :=
        JSON.Make_Object
          ([1 => (Key  => To_Unbounded_String ("var"),
                  Item => JSON.Make_String ("outcome"))]);
   begin
      return JSON.Make_Object
        ([1 => (Key  => To_Unbounded_String ("=="),
                Item => JSON.Make_Array
                          ([1 => Variable, 2 => JSON.Make_String (Name)]))]);
   end Outcome_Test;

   function Resolve
     (Defs            : Namespaces.Namespace;
      Name            : String;
      Default_Harness : Harnesses.Kind_Options.Option)
      return Resolve_Results.Result
   is
      Result : Resolved.Pipeline;

      function Failure
        (File : String; Where : Syntax.Reference; Message : String)
         return Resolve_Results.Result
      is
        (Resolve_Results.Failure
           (Source_Errors.With_File
              (Source_Errors.Make (Message, Where.Line, Where.Column),
               File)));

      --  Whether Named is a definition of the given kind.
      function Exists (Named : String; Kind : Syntax.Definition_Kind)
         return Boolean is
        (Namespaces.Contains (Defs, Named)
         and then Namespaces.Element (Defs, Named).Item.Kind = Kind);

      --  The attributes of the definition of the given kind a step names, if
      --  it names one.
      function Referred
        (List : Syntax.Attribute_Vectors.Vector; Attribute_Name : String;
         Kind : Syntax.Definition_Kind)
         return Syntax.Attribute_Vectors.Vector
      is
         C : constant Syntax.Attribute_Vectors.Cursor :=
           Find (List, Attribute_Name);
      begin
         if C /= Syntax.Attribute_Vectors.No_Element then
            declare
               Item  : constant Syntax.Value :=
                 Syntax.Attribute_Vectors.Element (C).Item;
               Named : constant String := Text_Of (Item);
            begin
               if Item.Kind = Syntax.Name_Value
                 and then Namespaces.Contains (Defs, Named)
                 and then Namespaces.Element (Defs, Named).Item.Kind = Kind
               then
                  return Namespaces.Element (Defs, Named).Item.Attributes;
               end if;
            end;
         end if;
         return Syntax.Attribute_Vectors.Empty_Vector;
      end Referred;

      function Merge_Step
        (S : Syntax.Step; File : String; Made : out Resolved.Step)
         return Resolve_Results.Result
      is
         Own     : Syntax.Attribute_Vectors.Vector renames S.Attributes;
         System  : constant Syntax.Attribute_Vectors.Vector :=
           Referred (Own, "System", Syntax.System_Definition);

         --  The step's own attribute, else its system's.
         function Pick (Attribute_Name : String)
            return Syntax.Attribute_Vectors.Cursor
         is
            Mine : constant Syntax.Attribute_Vectors.Cursor :=
              Find (Own, Attribute_Name);
         begin
            return (if Mine /= Syntax.Attribute_Vectors.No_Element
                    then Mine else Find (System, Attribute_Name));
         end Pick;

         function Picked (Attribute_Name : String) return Syntax.Value is
           (Syntax.Attribute_Vectors.Element
              (if Has (Own, Attribute_Name)
               then Find (Own, Attribute_Name)
               else Find (System, Attribute_Name)).Item);

         --  Whether the system or the step has the attribute.
         function Given (Attribute_Name : String) return Boolean is
           (Pick (Attribute_Name) /= Syntax.Attribute_Vectors.No_Element);

         Agent_Attributes : Syntax.Attribute_Vectors.Vector;
      begin
         Made.Name := S.Name.Name;

         if Has (Own, "System")
           and then Exists (Text_Of (Picked ("System")),
                            Syntax.System_Definition)
         then
            declare
               Named : constant String := Text_Of (Picked ("System"));
            begin
               Made.Origins.Append
                 (Resolved.Origin'
                    (Kind => Resolved.System_Origin,
                     Name => To_Unbounded_String (Named),
                     File => Namespaces.Element (Defs, Named).Path));
            end;
         end if;

         if Given ("Harness") then
            declare
               Found : constant Harnesses.Kind_Options.Option :=
                 Harnesses.Find (Text_Of (Picked ("Harness")));
            begin
               if not Found.Found then
                  return Failure
                    (File, S.Name,
                     "step '" & To_String (S.Name.Name)
                     & "' names a harness that does not exist");
               end if;
               Made.Harness := Found.Value;
            end;
         elsif Default_Harness.Found then
            Made.Harness := Default_Harness.Value;
         else
            return Failure
              (File, S.Name,
               "step '" & To_String (S.Name.Name) & "' has no harness");
         end if;

         if Given ("Agent") then
            declare
               Agent_Name : constant Syntax.Value := Picked ("Agent");
            begin
               Agent_Attributes :=
                 Referred
                   ((if Has (Own, "Agent") then Own else System), "Agent",
                    Syntax.Agent_Definition);
               if not Exists (Text_Of (Agent_Name), Syntax.Agent_Definition)
               then
                  return Failure
                    (File, S.Name,
                     "step '" & To_String (S.Name.Name) & "' names agent '"
                     & Text_Of (Agent_Name) & "', which there is not");
               end if;
            end;
         end if;
         Made.Role := Instruction_Of (Agent_Attributes);
         if Given ("Agent") then
            declare
               Named : constant String := Text_Of (Picked ("Agent"));
            begin
               Made.Origins.Append
                 (Resolved.Origin'
                    (Kind => Resolved.Agent_Origin,
                     Name => To_Unbounded_String (Named),
                     File => Namespaces.Element (Defs, Named).Path));
            end;
         end if;

         Made.Assignment :=
           (if Has (Own, "Prompt") or else Has (Own, "Skill")
            then Instruction_Of (Own) else Instruction_Of (System));

         if Given ("Model") then
            Made.Model :=
              Synapse.Core.Optional_Text.Of_Value
                (To_Unbounded_String (Text_Of (Picked ("Model"))));
         end if;
         if Given ("Permissions") then
            Made.Permissions :=
              Synapse.Core.Optional_Text.Of_Value
                (To_Unbounded_String (Text_Of (Picked ("Permissions"))));
         end if;
         if Given ("Tools") then
            Made.Tools :=
              Resolved.Json_Options.Of_Value (Picked ("Tools").Json);
         end if;
         if Given ("Timeout") then
            Made.Timeout_Seconds :=
              Durations.Seconds (Text_Of (Picked ("Timeout")));
         end if;
         if Given ("Retries") then
            Made.Retries := Natural (Picked ("Retries").Number);
         end if;
         return Resolve_Results.Success (Result);
      end Merge_Step;

      function Make_Edge (E : Syntax.Edge) return Resolved.Edge is
         Made : Resolved.Edge;
         C    : constant Syntax.Attribute_Vectors.Cursor :=
           Find (E.Attributes, "When");
         M    : constant Syntax.Attribute_Vectors.Cursor :=
           Find (E.Attributes, "Max_Iterations");
      begin
         Made.From := E.From.Name;
         Made.To := E.To.Name;
         if C /= Syntax.Attribute_Vectors.No_Element then
            declare
               Guard : constant Syntax.Value :=
                 Syntax.Attribute_Vectors.Element (C).Item;
            begin
               Made.Has_Guard := True;
               Made.Guard :=
                 (if Guard.Kind = Syntax.Name_Value
                  then Outcome_Test (To_String (Guard.Name))
                  else Guard.Json);
            end;
         end if;
         if M /= Syntax.Attribute_Vectors.No_Element then
            Made.Max_Iterations :=
              Natural (Syntax.Attribute_Vectors.Element (M).Item.Number);
         end if;
         return Made;
      end Make_Edge;
   begin
      if not Namespaces.Contains (Defs, Name)
        or else Namespaces.Element (Defs, Name).Item.Kind /=
                Syntax.Pipeline_Definition
      then
         return Resolve_Results.Failure
           (Source_Errors.Make
              ("there is no pipeline named '" & Name & "'", 1, 1));
      end if;
      declare
         Loaded : constant Namespaces.Loaded :=
           Namespaces.Element (Defs, Name);
         File   : constant String := To_String (Loaded.Path);
      begin
         Result.Name := To_Unbounded_String (Name);
         for S of Loaded.Item.Steps loop
            declare
               Made   : Resolved.Step :=
                 (Name => <>, Harness => Harnesses.Claude, Role => <>,
                  Assignment => <>, Model => <>, Permissions => <>,
                  Tools => <>, Timeout_Seconds => 0, Retries => 0,
                  Origins => <>);
               Merged : constant Resolve_Results.Result :=
                 Merge_Step (S, File, Made);
            begin
               if not Resolve_Results.Is_Success (Merged) then
                  return Merged;
               end if;
               Result.Steps.Append (Made);
            end;
         end loop;
         for E of Loaded.Item.Edges loop
            Result.Edges.Append (Make_Edge (E));
         end loop;
      end;
      return Resolve_Results.Success (Result);
   end Resolve;

end Synapse.Pipeline.Resolution;
