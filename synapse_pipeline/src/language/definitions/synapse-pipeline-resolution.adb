with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Data_Shapes;
with Synapse.Pipeline.Durations;
with Synapse.Pipeline.Efforts;
with Synapse.Pipeline.Limits;
with Synapse.Pipeline.Outcomes;
with Synapse.Pipeline.Syntax;

package body Synapse.Pipeline.Resolution is

   use Ada.Strings.Unbounded;
   use type Harnesses.Harness_Kind;
   use type Resolved.Origin_Kind;
   use type Synapse.Core.JSON.Kind;
   use type Syntax.Definition_Kind;
   use type Syntax.Value_Kind;
   use type Syntax.Attribute_Vectors.Cursor;

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

      --  The instruction a list of attributes gives through its `Prompt`:
      --  the text written in place, or the text of the Prompt definition it
      --  names. A named prompt is appended to Origins, once per name. Set
      --  Missing to the name when it names no loaded Prompt definition.
      function Instruction_Of
        (List    : Syntax.Attribute_Vectors.Vector;
         Origins : in out Resolved.Origin_Vectors.Vector;
         Missing : in out Unbounded_String)
         return Resolved.Instruction
      is
         C : constant Syntax.Attribute_Vectors.Cursor := Find (List, "Prompt");
      begin
         if C = Syntax.Attribute_Vectors.No_Element then
            return (Present => False);
         end if;
         declare
            Item : constant Syntax.Value :=
              Syntax.Attribute_Vectors.Element (C).Item;
         begin
            if Item.Kind /= Syntax.Name_Value then
               return (Present => True, Text => Item.Text);
            end if;
            declare
               Named  : constant String := To_String (Item.Name);
               Prompt : constant Syntax.Attribute_Vectors.Vector :=
                 Referred (List, "Prompt", Syntax.Prompt_Definition);
               Own    : constant Syntax.Attribute_Vectors.Cursor :=
                 Find (Prompt, "Prompt");
               Listed : Boolean := False;
            begin
               if not Exists (Named, Syntax.Prompt_Definition)
                 or else Own = Syntax.Attribute_Vectors.No_Element
               then
                  Missing := To_Unbounded_String (Named);
                  return (Present => False);
               end if;
               for O of Origins loop
                  if O.Kind = Resolved.Prompt_Origin
                    and then To_String (O.Name) = Named
                  then
                     Listed := True;
                  end if;
               end loop;
               if not Listed then
                  Origins.Append
                    (Resolved.Origin'
                       (Kind => Resolved.Prompt_Origin,
                        Name => To_Unbounded_String (Named),
                        File => Namespaces.Element (Defs, Named).Path));
               end if;
               return
                 (Present => True,
                  Text    => Syntax.Attribute_Vectors.Element (Own).Item.Text);
            end;
         end;
      end Instruction_Of;

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
         Missing          : Unbounded_String;

         --  Append to Named_Fields each of Names the pipeline declares and
         --  the step has not taken yet.
         procedure Took (Names : Synapse.Core.Text_Lists.Vector) is
         begin
            for N of Names loop
               if Data_Shapes.Declares (Result.Data, To_String (N))
                 and then not Made.Named_Fields.Contains (N)
               then
                  Made.Named_Fields.Append (N);
               end if;
            end loop;
         end Took;

         function No_Prompt return Resolve_Results.Result is
           (Failure
              (File, S.Name,
               "step '" & To_String (S.Name.Name) & "' names prompt '"
               & To_String (Missing) & "', which there is not"));
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

         Made.Role :=
           Instruction_Of (Agent_Attributes, Made.Origins, Missing);
         if Length (Missing) > 0 then
            return No_Prompt;
         end if;

         Made.Assignment :=
           Instruction_Of
             ((if Has (Own, "Prompt") then Own else System), Made.Origins,
              Missing);
         if Length (Missing) > 0 then
            return No_Prompt;
         end if;

         if Given ("Model") then
            Made.Model :=
              Synapse.Core.Optional_Text.Of_Value
                (To_Unbounded_String (Text_Of (Picked ("Model"))));
         end if;
         if Given ("Effort") then
            declare
               Value   : constant String := Text_Of (Picked ("Effort"));
               Harness : constant String := Harnesses.Name_Of (Made.Harness);
            begin
               if not Efforts.Is_Offered (Made.Harness, Value) then
                  return Failure
                    (File, S.Name,
                     "step '" & To_String (S.Name.Name) & "' asks " & Harness
                     & " for effort '" & Value & "'; "
                     & (if Efforts.Names (Made.Harness) = ""
                        then "that is not the name of a variant"
                        else Harness & " offers "
                             & Efforts.Names (Made.Harness)));
               end if;
               if Made.Harness = Harnesses.Opencode
                 and then not Made.Model.Found
               then
                  return Failure
                    (File, S.Name,
                     "step '" & To_String (S.Name.Name)
                     & "' names an OpenCode variant but no Model; OpenCode "
                     & "takes the variant as part of the model");
               end if;
               Made.Effort :=
                 Synapse.Core.Optional_Text.Of_Value
                   (To_Unbounded_String
                      (Efforts.Normalized (Made.Harness, Value)));
            end;
         end if;
         if Given ("Permissions") then
            Made.Permissions :=
              Synapse.Core.Optional_Text.Of_Value
                (To_Unbounded_String (Text_Of (Picked ("Permissions"))));
         end if;
         if Given ("Timeout") then
            Made.Timeout_Seconds :=
              Durations.Seconds (Text_Of (Picked ("Timeout")));
         end if;
         if Given ("Retries") then
            Made.Retries := Limits.Repeat_Count (Picked ("Retries").Number);
         end if;
         if Given ("Data") then
            Took (Data_Shapes.Names_Of (Picked ("Data").Json));
            Made.Data :=
              Data_Shapes.Resolve_Data (Result.Data, Picked ("Data").Json);
         end if;
         if Given ("Outcomes") then
            declare
               Declared : constant Synapse.Core.JSON.Value :=
                 Picked ("Outcomes").Json;
            begin
               if Synapse.Core.JSON.Kind_Of (Declared) =
                    Synapse.Core.JSON.JSON_Object
               then
                  for I in 1 .. Synapse.Core.JSON.Length (Declared) loop
                     Took
                       (Data_Shapes.Names_Of
                          (Outcomes.Data_Of
                             (Declared,
                              Synapse.Core.JSON.Member_Key (Declared, I))));
                  end loop;
               end if;
               Made.Outcomes :=
                 Data_Shapes.Resolve_Outcomes (Result.Data, Declared);
            end;
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
                  then Outcomes.Test_For (To_String (Guard.Name))
                  else Guard.Json);
            end;
         end if;
         if M /= Syntax.Attribute_Vectors.No_Element then
            Made.Max_Iterations :=
              Limits.Repeat_Count
                (Syntax.Attribute_Vectors.Element (M).Item.Number);
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
         if Has (Loaded.Item.Attributes, "Input") then
            Result.Input :=
              Syntax.Attribute_Vectors.Element
                (Find (Loaded.Item.Attributes, "Input")).Item.Json;
         end if;
         if Has (Loaded.Item.Attributes, "Data") then
            Result.Data :=
              Syntax.Attribute_Vectors.Element
                (Find (Loaded.Item.Attributes, "Data")).Item.Json;
         end if;
         for S of Loaded.Item.Steps loop
            declare
               Made   : Resolved.Step :=
                 (Name => <>, Harness => Harnesses.Claude, Role => <>,
                  Assignment => <>, Model => <>, Effort => <>,
                  Permissions => <>,
                  Timeout_Seconds => 0, Retries => 0, Outcomes => <>,
                  Data => <>, Named_Fields => <>, Origins => <>);
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
