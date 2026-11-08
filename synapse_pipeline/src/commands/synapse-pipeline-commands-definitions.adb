with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Definitions;
with Synapse.Pipeline.Namespaces;
with Synapse.Pipeline.Search_Paths;
with Synapse.Pipeline.Source_Errors;
with Synapse.Pipeline.Syntax;

package body Synapse.Pipeline.Commands.Definitions is

   use Ada.Strings.Unbounded;

   package JSON renames Synapse.Core.JSON;
   package Syn renames Synapse.Pipeline.Syntax;

   LF : constant Character := Character'Val (10);

   Format : constant String := "synapse-pipeline-definitions/v1";

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Definitions_Help);

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function Kind_Word (Kind : Syn.Definition_Kind) return String is
     (case Kind is
        when Syn.Pipeline_Definition => "pipeline",
        when Syn.System_Definition   => "system",
        when Syn.Agent_Definition    => "agent");

   function Problem_JSON (Item : Source_Errors.Source_Error) return JSON.Value
   is
     (JSON.Make_Object
        ([Member ("file", JSON.Make_String (To_String (Item.File))),
          Member ("line", JSON.Make_Integer (Long_Long_Integer (Item.Line))),
          Member
            ("column", JSON.Make_Integer (Long_Long_Integer (Item.Column))),
          Member ("message", JSON.Make_String (To_String (Item.Message)))]));

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      As_JSON : Boolean := False;
   begin
      if Natural (Args.Length) = 2
        and then To_String (Args.First_Element) = "--format"
        and then To_String (Args.Last_Element) in "json" | "text"
      then
         As_JSON := To_String (Args.Last_Element) = "json";
      elsif not Args.Is_Empty then
         return Usage_Error (Env, Usage);
      end if;
      declare
         Report : constant Synapse.Pipeline.Definitions.Load_Report :=
           Synapse.Pipeline.Definitions.Load
             (Env.Files.all, Search_Paths.Definition_Roots (Env.Vars.all));
         Names  : constant Synapse.Core.Text_Lists.Vector :=
           Namespaces.Names (Report.Definitions);
         Found  : JSON.Value_Array (1 .. Natural (Names.Length));
         Broken : JSON.Value_Array (1 .. Natural (Report.Problems.Length));
         Text   : Unbounded_String;
      begin
         for I in Found'Range loop
            declare
               Loaded : constant Namespaces.Loaded :=
                 Namespaces.Element (Report.Definitions, To_String (Names (I)));
               Kind   : constant String := Kind_Word (Loaded.Item.Kind);
            begin
               Found (I) :=
                 JSON.Make_Object
                   ([Member ("kind", JSON.Make_String (Kind)),
                     Member ("name", JSON.Make_String (To_String (Names (I)))),
                     Member
                       ("file", JSON.Make_String (To_String (Loaded.Path)))]);
               Append
                 (Text,
                  Kind & " " & To_String (Names (I)) & "  "
                  & To_String (Loaded.Path) & LF);
            end;
         end loop;
         for I in Broken'Range loop
            Broken (I) := Problem_JSON (Report.Problems (I));
            Append
              (Text, Synapse.Pipeline.Definitions.Warning (Report.Problems (I))
               & LF);
         end loop;
         Say
           (Env,
            (if As_JSON
             then JSON.To_String
                    (JSON.Make_Object
                       ([Member ("format", JSON.Make_String (Format)),
                         Member ("definitions", JSON.Make_Array (Found)),
                         Member ("problems", JSON.Make_Array (Broken))]))
                  & LF
             else To_String (Text)));
         return 0;
      end;
   end Run;

end Synapse.Pipeline.Commands.Definitions;
