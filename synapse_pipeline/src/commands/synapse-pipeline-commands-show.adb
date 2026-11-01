with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Loading;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Descriptions;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Search_Paths;

package body Synapse.Pipeline.Commands.Show is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

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

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Name       : Unbounded_String;
      Format     : Unbounded_String := To_Unbounded_String ("text");
      Has_Format : Boolean := False;
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
      then
         return Usage_Error (Env, Usage);
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
         declare
            Document : constant JSON.Value :=
              Descriptions.Describe
                (Item, Configs.Config_Results.Value (Settled));
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
