with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Attributes;
with Synapse.Pipeline.Skills;
with Synapse.Pipeline.Source_Errors;
with Synapse.Pipeline.Syntax;

package body Synapse.Pipeline.Validation is

   use Ada.Strings.Unbounded;
   use type Syntax.Definition_Kind;
   use type Syntax.Value_Kind;

   function Kind_Word (Kind : Syntax.Definition_Kind) return String is
     (case Kind is
        when Syntax.Pipeline_Definition => "pipeline",
        when Syntax.System_Definition   => "system",
        when Syntax.Agent_Definition    => "agent");

   function Article (Kind : Syntax.Definition_Kind) return String is
     (if Kind = Syntax.Agent_Definition then "an " else "a ");

   function Name_Of (Item : Syntax.Reference) return String is
     (To_String (Item.Name));

   function Has_Attribute
     (List : Syntax.Attribute_Vectors.Vector; Name : String) return Boolean is
     (for some A of List => Name_Of (A.Name) = Name);

   function Has_Instructions
     (List : Syntax.Attribute_Vectors.Vector) return Boolean is
     (Has_Attribute (List, "Prompt") or else Has_Attribute (List, "Skill"));

   function Validate
     (Defs        : Namespaces.Namespace;
      Files       : File_System.File_System'Class;
      Skill_Roots : Search_Paths.Root_Vectors.Vector;
      Name        : String;
      Default_Harness : Harnesses.Kind_Options.Option)
      return Definitions.Problem_Vectors.Vector
   is
      Problems : Definitions.Problem_Vectors.Vector;

      --  The systems and agents already checked, so each is checked once.
      Checked : Synapse.Core.Text_Lists.Set;

      procedure Add (File : String; Error : Source_Errors.Source_Error) is
      begin
         Problems.Append (Source_Errors.With_File (Error, File));
      end Add;

      procedure Add_At
        (File : String; Where : Syntax.Reference; Message : String) is
      begin
         Add (File, Source_Errors.Make (Message, Where.Line, Where.Column));
      end Add_At;

      --  The attributes of one definition or node, each checked on its own,
      --  and then as a list.
      procedure Check_Attributes
        (File  : String; Where : Attributes.Context;
         List  : Syntax.Attribute_Vectors.Vector)
      is
         Seen : Synapse.Core.Text_Lists.Set;
      begin
         for A of List loop
            declare
               Attribute_Name : constant String := Name_Of (A.Name);
               Found          : constant Attributes.Error_Options.Option :=
                 Attributes.Check (Where, A);
            begin
               if Found.Found then
                  Add (File, Found.Value);
               elsif Seen.Contains (Attribute_Name) then
                  Add_At
                    (File, A.Name,
                     "'" & Attribute_Name & "' is given more than once");
               end if;
               Seen.Include (Attribute_Name);

               if not Found.Found and then Attribute_Name = "Skill" then
                  declare
                     Skill : constant String := To_String (A.Item.Text);
                  begin
                     if not Skills.Find (Files, Skill_Roots, Skill).Found then
                        Add
                          (File,
                           Source_Errors.Make
                             ("no skill named '" & Skill & "' in "
                              & (if Skill_Roots.Is_Empty
                                 then "any skill directory (none is set up)"
                                 else Skills.Searched (Skill_Roots)),
                              A.Item.Line, A.Item.Column));
                     end if;
                  end;
               end if;
            end;
         end loop;
         if Has_Attribute (List, "Prompt")
           and then Has_Attribute (List, "Skill")
         then
            for A of List loop
               if Name_Of (A.Name) = "Skill" then
                  Add_At
                    (File, A.Name,
                     "'Prompt' and 'Skill' are both given; a definition "
                     & "takes one instruction source");
                  exit;
               end if;
            end loop;
         end if;
      end Check_Attributes;

      --  What is wrong with a reference to the Expected kind of definition,
      --  said at the reference. True when it names one that can be used.
      function Resolves
        (File     : String; Reference : Syntax.Attribute;
         Expected : Syntax.Definition_Kind) return Boolean
      is
         Referred : constant String := To_String (Reference.Item.Name);
         Wanted   : constant String := Kind_Word (Expected);

         procedure Fail (Message : String) is
         begin
            Add
              (File,
               Source_Errors.Make
                 (Message, Reference.Item.Line, Reference.Item.Column));
         end Fail;
      begin
         if Reference.Item.Kind /= Syntax.Name_Value then
            return False;
         elsif Namespaces.Has_Failed (Defs, Referred) then
            Fail
              (Wanted & " '" & Referred & "' failed to load: "
               & Source_Errors.Image (Namespaces.Failure (Defs, Referred)));
            return False;
         elsif not Namespaces.Contains (Defs, Referred) then
            Fail ("there is no " & Wanted & " named '" & Referred & "'");
            return False;
         elsif Namespaces.Element (Defs, Referred).Item.Kind /= Expected then
            Fail
              ("'" & Referred & "' is "
               & Article (Namespaces.Element (Defs, Referred).Item.Kind)
               & Kind_Word (Namespaces.Element (Defs, Referred).Item.Kind)
               & ", not " & Article (Expected) & Wanted);
            return False;
         end if;
         return True;
      end Resolves;

      procedure Check_Definition (Referred : String);

      --  The attribute called Attribute_Name in List, if there is one.
      function Find
        (List : Syntax.Attribute_Vectors.Vector; Attribute_Name : String)
         return Syntax.Attribute_Vectors.Cursor
      is
      begin
         for C in List.Iterate loop
            if Name_Of (Syntax.Attribute_Vectors.Element (C).Name) =
               Attribute_Name
            then
               return C;
            end if;
         end loop;
         return Syntax.Attribute_Vectors.No_Element;
      end Find;

      use type Syntax.Attribute_Vectors.Cursor;

      --  Whether a system gives instructions: itself, or through its agent.
      --  Nothing is reported; checking the system does that.
      function System_Instructs (Item : Syntax.Definition) return Boolean is
         C : constant Syntax.Attribute_Vectors.Cursor :=
           Find (Item.Attributes, "Agent");
      begin
         if Has_Instructions (Item.Attributes) then
            return True;
         elsif C = Syntax.Attribute_Vectors.No_Element then
            return False;
         end if;
         declare
            Reference : constant Syntax.Attribute :=
              Syntax.Attribute_Vectors.Element (C);
            Referred  : constant String := To_String (Reference.Item.Name);
         begin
            return Reference.Item.Kind = Syntax.Name_Value
              and then Namespaces.Contains (Defs, Referred)
              and then Namespaces.Element (Defs, Referred).Item.Kind =
                       Syntax.Agent_Definition
              and then Has_Instructions
                         (Namespaces.Element (Defs, Referred).Item.Attributes);
         end;
      end System_Instructs;

      --  Whether the system a step names gives it a harness. Nothing is
      --  reported; following the reference does that.
      function System_Has_Harness
        (List : Syntax.Attribute_Vectors.Vector) return Boolean
      is
         C : constant Syntax.Attribute_Vectors.Cursor := Find (List, "System");
      begin
         if C = Syntax.Attribute_Vectors.No_Element then
            return False;
         end if;
         declare
            Reference : constant Syntax.Attribute :=
              Syntax.Attribute_Vectors.Element (C);
            Referred  : constant String := To_String (Reference.Item.Name);
         begin
            return Reference.Item.Kind = Syntax.Name_Value
              and then Namespaces.Contains (Defs, Referred)
              and then Namespaces.Element (Defs, Referred).Item.Kind =
                       Syntax.System_Definition
              and then Has_Attribute
                         (Namespaces.Element (Defs, Referred).Item.Attributes,
                          "Harness");
         end;
      end System_Has_Harness;

      --  Checks the system or the agent that the attribute Attribute_Name of
      --  List names, if there is one. Resolved says whether it could be used,
      --  and Instructed whether it, or what it names, gives instructions.
      procedure Follow
        (File : String; List : Syntax.Attribute_Vectors.Vector;
         Attribute_Name : String; Expected : Syntax.Definition_Kind;
         Resolved : in out Boolean; Instructed : in out Boolean)
      is
         C : constant Syntax.Attribute_Vectors.Cursor :=
           Find (List, Attribute_Name);
      begin
         if C = Syntax.Attribute_Vectors.No_Element then
            return;
         end if;
         declare
            Reference : constant Syntax.Attribute :=
              Syntax.Attribute_Vectors.Element (C);
            Referred  : constant String := To_String (Reference.Item.Name);
         begin
            if not Resolves (File, Reference, Expected) then
               Resolved := False;
               return;
            end if;
            Check_Definition (Referred);
            declare
               Item : constant Syntax.Definition :=
                 Namespaces.Element (Defs, Referred).Item;
            begin
               Instructed :=
                 Instructed
                 or else (if Expected = Syntax.Agent_Definition
                          then Has_Instructions (Item.Attributes)
                          else System_Instructs (Item));
            end;
         end;
      end Follow;

      --  Checks a system or an agent, once.
      procedure Check_Definition (Referred : String) is
         Loaded : constant Namespaces.Loaded :=
           Namespaces.Element (Defs, Referred);
         Item   : Syntax.Definition renames Loaded.Item;
         File   : constant String := To_String (Loaded.Path);
      begin
         if Checked.Contains (Referred) then
            return;
         end if;
         Checked.Include (Referred);
         if Item.Kind = Syntax.System_Definition then
            Check_Attributes
              (File, Attributes.System_Context, Item.Attributes);
            declare
               Resolved   : Boolean := True;
               Instructed : Boolean := False;
            begin
               Follow
                 (File, Item.Attributes, "Agent", Syntax.Agent_Definition,
                  Resolved, Instructed);
            end;
         elsif Item.Kind = Syntax.Agent_Definition then
            Check_Attributes
              (File, Attributes.Agent_Context, Item.Attributes);
         end if;
      end Check_Definition;

      package Step_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (String, Positive);

      procedure Check_Pipeline (Loaded : Namespaces.Loaded) is
         Item  : Syntax.Definition renames Loaded.Item;
         File  : constant String := To_String (Loaded.Path);
         Index : Step_Maps.Map;
         Count : Natural := 0;
      begin
         if Item.Steps.Is_Empty then
            Add_At (File, Item.Name, "a pipeline needs at least one step");
         end if;

         for S of Item.Steps loop
            Count := Count + 1;
            declare
               Step_Name : constant String := Name_Of (S.Name);
            begin
               if Index.Contains (Step_Name) then
                  Add_At
                    (File, S.Name,
                     "step '" & Step_Name & "' is already declared as step"
                     & Natural'Image (Index.Element (Step_Name)));
               else
                  Index.Insert (Step_Name, Count);
               end if;
            end;
            Check_Attributes (File, Attributes.Step_Context, S.Attributes);
            declare
               Resolved   : Boolean := True;
               Instructed : Boolean := Has_Instructions (S.Attributes);
            begin
               Follow
                 (File, S.Attributes, "System", Syntax.System_Definition,
                  Resolved, Instructed);
               Follow
                 (File, S.Attributes, "Agent", Syntax.Agent_Definition,
                  Resolved, Instructed);
               if Resolved and then not Default_Harness.Found
                 and then not Has_Attribute (S.Attributes, "Harness")
                 and then not System_Has_Harness (S.Attributes)
               then
                  Add_At
                    (File, S.Name,
                     "step '" & Name_Of (S.Name) & "' has no harness: give "
                     & "a Harness, use a System that has one, or set the "
                     & "default harness");
               end if;
               if Resolved and then not Instructed then
                  Add_At
                    (File, S.Name,
                     "step '" & Name_Of (S.Name) & "' has no instructions: "
                     & "give a Prompt or a Skill, or an Agent or a System "
                     & "that has one");
               end if;
            end;
         end loop;

         for E of Item.Edges loop
            declare
               From_Known : constant Boolean :=
                 Index.Contains (Name_Of (E.From));
               To_Known   : constant Boolean :=
                 Index.Contains (Name_Of (E.To));
            begin
               if not From_Known then
                  Add_At
                    (File, E.From,
                     "there is no step named '" & Name_Of (E.From) & "'");
               end if;
               if not To_Known then
                  Add_At
                    (File, E.To,
                     "there is no step named '" & Name_Of (E.To) & "'");
               end if;
               Check_Attributes (File, Attributes.Edge_Context, E.Attributes);
               if From_Known and then To_Known
                 and then Index.Element (Name_Of (E.To)) <=
                          Index.Element (Name_Of (E.From))
                 and then not Has_Attribute (E.Attributes, "Max_Iterations")
               then
                  Add_At
                    (File, E.From,
                     "the edge back to '" & Name_Of (E.To) & "' needs "
                     & "Max_Iterations, so that the cycle is bounded");
               end if;
            end;
         end loop;
      end Check_Pipeline;
   begin
      if Namespaces.Has_Failed (Defs, Name) then
         Problems.Append (Namespaces.Failure (Defs, Name));
      elsif not Namespaces.Contains (Defs, Name) then
         Problems.Append
           (Source_Errors.Make
              ("there is no pipeline named '" & Name & "'", 1, 1));
      elsif Namespaces.Element (Defs, Name).Item.Kind /=
            Syntax.Pipeline_Definition
      then
         Problems.Append
           (Source_Errors.With_File
              (Source_Errors.Make
                 ("'" & Name & "' is "
                  & Article (Namespaces.Element (Defs, Name).Item.Kind)
                  & Kind_Word (Namespaces.Element (Defs, Name).Item.Kind)
                  & ", not a pipeline", 1, 1),
               To_String (Namespaces.Element (Defs, Name).Path)));
      else
         Check_Pipeline (Namespaces.Element (Defs, Name));
      end if;
      return Problems;
   end Validate;

end Synapse.Pipeline.Validation;
