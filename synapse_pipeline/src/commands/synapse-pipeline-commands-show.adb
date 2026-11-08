with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Loading;
with Synapse.Pipeline.Definitions;
with Synapse.Pipeline.Namespaces;
with Synapse.Pipeline.Syntax;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Descriptions;
with Synapse.Pipeline.Instructions;
with Synapse.Pipeline.Prompts;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Search_Paths;

package body Synapse.Pipeline.Commands.Show is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Prompt_Format : constant String := "synapse-pipeline-prompt/v1";

   --  What stands where the result of the step before is handed over.
   Slot : constant String :=
     "<the result of the step before, as it reports it when this step runs>";

   Definition_Format : constant String := "synapse-pipeline-definition/v1";

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Show_Help);

   function Text_Of (Item : JSON.Value; Key : String) return String is
     (if JSON.Has_Member (Item, Key)
        and then JSON.Kind_Of (JSON.Member_Value (Item, Key)) =
                 JSON.JSON_String
      then JSON.As_String (JSON.Member_Value (Item, Key)) else "");

   --  A member as it reads on a line: its text, or `-` when it has none.
   function Shown (Item : JSON.Value; Key : String) return String is
     (if JSON.Kind_Of (JSON.Member_Value (Item, Key)) = JSON.JSON_Null
      then "-"
      elsif JSON.Kind_Of (JSON.Member_Value (Item, Key)) = JSON.JSON_String
      then JSON.As_String (JSON.Member_Value (Item, Key))
      else JSON.To_String (JSON.Member_Value (Item, Key)));

   package Syn renames Synapse.Pipeline.Syntax;

   use type Syn.Definition_Kind;
   use type Syn.Value_Kind;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function Kind_Word (Kind : Syn.Definition_Kind) return String is
     (case Kind is
        when Syn.Pipeline_Definition => "pipeline",
        when Syn.System_Definition   => "system",
        when Syn.Agent_Definition    => "agent");

   function Value_JSON (Item : Syn.Value) return JSON.Value is
     (case Item.Kind is
        when Syn.Name_Value    => JSON.Make_String (To_String (Item.Name)),
        when Syn.String_Value  => JSON.Make_String (To_String (Item.Text)),
        when Syn.Integer_Value => JSON.Make_Integer (Item.Number),
        when Syn.JSON_Value    => Item.Json);

   --  Whether one of Attributes is called Key and names Target.
   function Names_Target
     (Attributes : Syn.Attribute_Vectors.Vector; Key, Target : String)
      return Boolean is
   begin
      for A of Attributes loop
         if To_String (A.Name.Name) = Key
           and then A.Item.Kind = Syn.Name_Value
           and then To_String (A.Item.Name) = Target
         then
            return True;
         end if;
      end loop;
      return False;
   end Names_Target;

   function Uses
     (Item : Syn.Definition; Name : String; Kind : Syn.Definition_Kind)
      return Boolean
   is
      Key : constant String :=
        (if Kind = Syn.System_Definition then "System" else "Agent");
   begin
      case Item.Kind is
         when Syn.Pipeline_Definition =>
            for S of Item.Steps loop
               if Names_Target (S.Attributes, Key, Name) then
                  return True;
               end if;
            end loop;
            return False;
         when Syn.System_Definition =>
            return Kind = Syn.Agent_Definition
              and then Names_Target (Item.Attributes, Key, Name);
         when Syn.Agent_Definition =>
            return False;
      end case;
   end Uses;

   --  The definitions that name Name, a system or an agent, in alphabetical
   --  order: each as an object of its kind, name and file.
   function Used_By
     (Defs : Namespaces.Namespace; Name : String; Kind : Syn.Definition_Kind)
      return JSON.Value
   is
      Found : constant Synapse.Core.Text_Lists.Vector :=
        Namespaces.Names (Defs);
      Items : JSON.Value_Array (1 .. Natural (Found.Length));
      Last  : Natural := 0;
   begin
      for N of Found loop
         declare
            Other : constant Namespaces.Loaded :=
              Namespaces.Element (Defs, To_String (N));
         begin
            if Uses (Other.Item, Name, Kind) then
               Last := Last + 1;
               Items (Last) :=
                 JSON.Make_Object
                   ([Member ("kind", JSON.Make_String
                                       (Kind_Word (Other.Item.Kind))),
                     Member ("name", JSON.Make_String (To_String (N))),
                     Member ("file", JSON.Make_String
                                       (To_String (Other.Path)))]);
            end if;
         end;
      end loop;
      return JSON.Make_Array (Items (1 .. Last));
   end Used_By;

   --  A system or an agent: its attributes as written and who uses it.
   function Definition_Document
     (Defs : Namespaces.Namespace; Name : String) return JSON.Value
   is
      Loaded     : constant Namespaces.Loaded :=
        Namespaces.Element (Defs, Name);
      Attributes : constant Syn.Attribute_Vectors.Vector :=
        Loaded.Item.Attributes;
      Written    : JSON.Value_Array (1 .. Natural (Attributes.Length));
   begin
      for I in Written'Range loop
         Written (I) :=
           JSON.Make_Object
             ([Member ("name", JSON.Make_String
                                 (To_String (Attributes (I).Name.Name))),
               Member ("value", Value_JSON (Attributes (I).Item))]);
      end loop;
      return JSON.Make_Object
        ([Member ("format", JSON.Make_String (Definition_Format)),
          Member ("kind", JSON.Make_String (Kind_Word (Loaded.Item.Kind))),
          Member ("name", JSON.Make_String (Name)),
          Member ("file", JSON.Make_String (To_String (Loaded.Path))),
          Member ("attributes", JSON.Make_Array (Written)),
          Member ("used_by", Used_By (Defs, Name, Loaded.Item.Kind))]);
   end Definition_Document;

   function Definition_Layout (Document : JSON.Value) return String is
      Attributes : constant JSON.Value :=
        JSON.Member_Value (Document, "attributes");
      Users      : constant JSON.Value :=
        JSON.Member_Value (Document, "used_by");
      Result     : Unbounded_String;
   begin
      Append
        (Result,
         Text_Of (Document, "kind") & " " & Text_Of (Document, "name") & "  "
         & Text_Of (Document, "file") & LF);
      for I in 1 .. JSON.Length (Attributes) loop
         declare
            A : constant JSON.Value := JSON.Element (Attributes, I);
         begin
            Append
              (Result, "  " & Text_Of (A, "name") & " " & Shown (A, "value")
               & LF);
         end;
      end loop;
      for I in 1 .. JSON.Length (Users) loop
         declare
            U : constant JSON.Value := JSON.Element (Users, I);
         begin
            Append
              (Result, "  used by " & Text_Of (U, "kind") & " "
               & Text_Of (U, "name") & LF);
         end;
      end loop;
      if JSON.Length (Users) = 0 then
         Append (Result, "  used by nothing" & LF);
      end if;
      return To_String (Result);
   end Definition_Layout;

   --  A role or assignment: what kind it is and, for a prompt, how long.
   function Instruction_Line (Item : JSON.Value; Key : String) return String
   is
      Given : constant JSON.Value := JSON.Member_Value (Item, Key);
   begin
      if JSON.Kind_Of (Given) /= JSON.JSON_Object then
         return "-";
      elsif Text_Of (Given, "kind") = "skill" then
         return "skill " & Text_Of (Given, "name");
      end if;
      return "prompt," & Natural'Image (Text_Of (Given, "text")'Length)
        & " characters";
   end Instruction_Line;

   --  The description for a person.
   function Layout (Document : JSON.Value) return String is
      Steps  : constant JSON.Value := JSON.Member_Value (Document, "steps");
      Edges  : constant JSON.Value := JSON.Member_Value (Document, "edges");
      Limits : constant JSON.Value := JSON.Member_Value (Document, "limits");
      Result : Unbounded_String;
   begin
      Append (Result, "pipeline " & Text_Of (Document, "name") & LF);
      for I in 1 .. JSON.Length (Steps) loop
         declare
            S : constant JSON.Value := JSON.Element (Steps, I);
         begin
            Append
              (Result,
               "  step " & Text_Of (S, "name") & "  harness "
               & Text_Of (S, "harness") & "  model " & Shown (S, "model")
               & "  permissions " & Text_Of (S, "permissions") & "  timeout "
               & Shown (S, "timeout_seconds") & "s  retries "
               & Shown (S, "retries") & LF
               & "    role " & Instruction_Line (S, "role") & LF
               & "    assignment " & Instruction_Line (S, "assignment") & LF);
            declare
               Origins : constant JSON.Value :=
                 JSON.Member_Value (S, "origins");
            begin
               for K in 1 .. JSON.Length (Origins) loop
                  declare
                     O : constant JSON.Value := JSON.Element (Origins, K);
                  begin
                     Append
                       (Result,
                        "    " & Text_Of (O, "kind") & " "
                        & Text_Of (O, "name") & "  " & Text_Of (O, "file")
                        & LF);
                  end;
               end loop;
            end;
         end;
      end loop;
      for I in 1 .. JSON.Length (Edges) loop
         declare
            E : constant JSON.Value := JSON.Element (Edges, I);
         begin
            Append
              (Result,
               "  edge " & Shown (E, "index") & "  " & Text_Of (E, "from")
               & " -> " & Text_Of (E, "to") & "  guard " & Shown (E, "guard")
               & "  max iterations " & Shown (E, "max_iterations") & LF);
         end;
      end loop;
      Append
        (Result,
         "  limits  timeout " & Shown (Limits, "default_timeout_seconds")
         & "s  steps " & Shown (Limits, "step_ceiling") & "  runner "
         & Text_Of (Limits, "runner") & LF);
      return To_String (Result);
   end Layout;

   --  The description of a pipeline, with the kind and file it is for.
   function With_Origin (Description : JSON.Value; File : String)
      return JSON.Value
   is
      Count   : constant Natural := JSON.Length (Description);
      Members : JSON.Member_Array (1 .. Count + 3);
   begin
      for I in 1 .. Count loop
         Members (I) :=
           Member (JSON.Member_Key (Description, I),
                   JSON.Member_At (Description, I));
      end loop;
      Members (Count + 1) := Member ("kind", JSON.Make_String ("pipeline"));
      Members (Count + 2) := Member ("file", JSON.Make_String (File));
      Members (Count + 3) := Member ("used_by", JSON.Make_Array ([]));
      return JSON.Make_Object (Members);
   end With_Origin;

   --  The system or agent called Name, as a definition document, or False
   --  when Name is not one.
   function Print_Definition
     (Env : Environment; Name, Format : String) return Boolean
   is
      Report : constant Definitions.Load_Report :=
        Definitions.Load
          (Env.Files.all, Search_Paths.Definition_Roots (Env.Vars.all));
   begin
      if not Namespaces.Contains (Report.Definitions, Name)
        or else Namespaces.Element (Report.Definitions, Name).Item.Kind =
                Syn.Pipeline_Definition
      then
         return False;
      end if;
      for P of Report.Problems loop
         Complain (Env, Definitions.Warning (P) & LF);
      end loop;
      declare
         Document : constant JSON.Value :=
           Definition_Document (Report.Definitions, Name);
      begin
         Say
           (Env,
            (if Format = "json" then JSON.To_String (Document) & LF
             else Definition_Layout (Document)));
      end;
      return True;
   end Print_Definition;

   function Prompt_Document (Pipeline, Step, Prompt : String) return JSON.Value
   is
     (JSON.Make_Object
        ([Member ("format", JSON.Make_String (Prompt_Format)),
          Member ("pipeline", JSON.Make_String (Pipeline)),
          Member ("step", JSON.Make_String (Step)),
          Member ("prompt", JSON.Make_String (Prompt))]));

   --  The prompt the step called Step_Name would be started with. The input
   --  is what Input_Path holds, when it is given; for a step after the first
   --  what the step before reported is a marked slot.
   function Print_Prompt
     (Env         : Environment;
      Item        : Resolved.Pipeline;
      Skill_Roots : Search_Paths.Root_Vectors.Vector;
      Step_Name   : String;
      Input_Path  : String;
      Format      : String) return Exit_Code
   is
      Input : JSON.Value := JSON.Null_Value;
      Read  : Boolean := True;
   begin
      for Index in Item.Steps.First_Index .. Item.Steps.Last_Index loop
         if To_String (Item.Steps (Index).Name) = Step_Name then
            if Input_Path'Length > 0 then
               Loading.Read_Input (Env, Input_Path, Input, Read);
               if not Read then
                  return 1;
               end if;
            end if;
            declare
               Chosen  : constant Resolved.Step := Item.Steps (Index);
               Role    : Unbounded_String;
               Task_Of : Unbounded_String;
               Folder  : Unbounded_String;
               Problem : Unbounded_String;
            begin
               Instructions.Text_Of
                 (Env.Files.all, Skill_Roots, Chosen.Role, Role, Folder,
                  Problem);
               if Length (Problem) = 0 then
                  Instructions.Text_Of
                    (Env.Files.all, Skill_Roots, Chosen.Assignment, Task_Of,
                     Folder, Problem);
               end if;
               if Length (Problem) > 0 then
                  Complain (Env, "error: " & To_String (Problem) & LF);
                  return 1;
               end if;
               declare
                  Prompt : constant String :=
                    Prompts.Build
                      (Role            => To_String (Role),
                       Assignment      => To_String (Task_Of),
                       Step            => Step_Name,
                       Initial_Input   => Input,
                       Previous_Output =>
                         (if Index = Item.Steps.First_Index
                          then JSON.Null_Value
                          else JSON.Make_String (Slot)));
               begin
                  Say
                    (Env,
                     (if Format = "json"
                      then JSON.To_String
                             (Prompt_Document
                                (To_String (Item.Name), Step_Name, Prompt))
                           & LF
                      else Prompt));
                  return 0;
               end;
            end;
         end if;
      end loop;
      Complain
        (Env,
         "error: pipeline " & To_String (Item.Name) & " has no step "
         & Step_Name & LF);
      return 1;
   end Print_Prompt;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Name       : Unbounded_String;
      Format     : Unbounded_String := To_Unbounded_String ("text");
      Has_Format : Boolean := False;
      Step       : Unbounded_String;
      Input_Path : Unbounded_String;
      I          : Positive := Args.First_Index;
   begin
      while I <= Args.Last_Index loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Arg = "--format" then
               if Has_Format or else I = Args.Last_Index then
                  return Usage_Error (Env, Usage);
               end if;
               Has_Format := True;
               I := I + 1;
               Format := Args (I);
            elsif Arg in "--step" | "--input" then
               if I = Args.Last_Index
                 or else Length (if Arg = "--step" then Step else Input_Path)
                         > 0
               then
                  return Usage_Error (Env, Usage);
               end if;
               I := I + 1;
               if Arg = "--step" then
                  Step := Args (I);
               else
                  Input_Path := Args (I);
               end if;
            elsif Arg'Length >= 2
              and then Arg (Arg'First .. Arg'First + 1) = "--"
            then
               return Usage_Error (Env, Usage);
            elsif Length (Name) > 0 then
               return Usage_Error (Env, Usage);
            else
               Name := Args (I);
            end if;
         end;
         I := I + 1;
      end loop;
      if Length (Name) = 0
        or else To_String (Format) not in "text" | "json"
        or else (Length (Input_Path) > 0 and then Length (Step) = 0)
      then
         return Usage_Error (Env, Usage);
      end if;

      if Length (Step) = 0
        and then Print_Definition (Env, To_String (Name), To_String (Format))
      then
         return 0;
      end if;

      declare
         Settled     : constant Configs.Config_Results.Result :=
           Configs.Resolve (Env.Vars.all, Env.Files.Current_Directory);
         Ok          : Boolean;
         Item        : Resolved.Pipeline;
         File        : Unbounded_String;
         Skill_Roots : Search_Paths.Root_Vectors.Vector;
      begin
         if not Configs.Config_Results.Is_Success (Settled) then
            Complain
              (Env,
               "error: " & To_String (Configs.Config_Results.Error (Settled))
               & LF);
            return 1;
         end if;
         Loading.Load (Env, To_String (Name), Ok, Item, File, Skill_Roots);
         if not Ok then
            return 1;
         end if;
         if Length (Step) > 0 then
            return Print_Prompt
              (Env, Item, Skill_Roots, To_String (Step),
               To_String (Input_Path), To_String (Format));
         end if;
         declare
            Document : constant JSON.Value :=
              With_Origin
                (Descriptions.Describe
                   (Item, Configs.Config_Results.Value (Settled)),
                 To_String (File));
         begin
            Say
              (Env,
               (if To_String (Format) = "json"
                then JSON.To_String (Document) & LF
                else Layout (Document)));
            return 0;
         end;
      end;
   end Run;

end Synapse.Pipeline.Commands.Show;
