with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Loading;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Engine;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Search_Paths;
with Synapse.Pipeline.States;

package body Synapse.Pipeline.Commands.Next is

   use Ada.Strings.Unbounded;
   use type States.Run_Status;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Next_Help);

   --  The text of a file, or of standard input for `-`. Says what is wrong
   --  and leaves Ok False when it cannot be read.
   procedure Read_Source
     (Env   : Environment;
      Path  : String;
      Label : String;
      Text  : out Unbounded_String;
      Ok    : out Boolean) is
   begin
      if Path = "-" then
         Text := To_Unbounded_String (Env.Console.Read_Stdin);
         Ok := True;
         return;
      end if;
      declare
         Found : constant File_System.Maybe_Content := Env.Files.Read (Path);
      begin
         Ok := Found.Found;
         if Found.Found then
            Text := Found.Value;
         else
            Complain
              (Env, "error: " & Label & " " & Path & " cannot be read" & LF);
         end if;
      end;
   end Read_Source;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Name       : Unbounded_String;
      Input_Path : Unbounded_String;
      State_Path : Unbounded_String;
      Result_Path : Unbounded_String;
      Has_Input  : Boolean := False;
      Has_State  : Boolean := False;
      Has_Result : Boolean := False;
      I          : Positive := Args.First_Index;
   begin
      while I <= Args.Last_Index loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Arg in "--input" | "--state" | "--result" then
               if I = Args.Last_Index
                 or else (Arg = "--input" and then Has_Input)
                 or else (Arg = "--state" and then Has_State)
                 or else (Arg = "--result" and then Has_Result)
               then
                  return Usage_Error (Env, Usage);
               end if;
               I := I + 1;
               if Arg = "--input" then
                  Has_Input := True;
                  Input_Path := Args (I);
               elsif Arg = "--state" then
                  Has_State := True;
                  State_Path := Args (I);
               else
                  Has_Result := True;
                  Result_Path := Args (I);
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
        or else Has_State /= Has_Result
        or else (Has_State and then Has_Input)
        or else (Has_State and then State_Path = Result_Path
                 and then State_Path = "-")
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
         Text        : Unbounded_String;
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

         if not Has_State then
            declare
               Input : JSON.Value := JSON.Null_Value;
            begin
               if Has_Input then
                  Read_Source
                    (Env, To_String (Input_Path), "--input", Text, Ok);
                  if not Ok then
                     return 1;
                  end if;
                  declare
                     Parsed : constant JSON.Parse_Result :=
                       JSON.Parse (To_String (Text));
                  begin
                     if not Parsed.Ok then
                        Complain
                          (Env,
                           "error: --input " & To_String (Input_Path)
                           & " is not JSON: "
                           & JSON.Parse_Error_Kind'Image (Parsed.Error)
                           & " at byte" & Natural'Image (Parsed.Offset) & LF);
                        return 1;
                     end if;
                     Input := Parsed.Item;
                  end;
               end if;
               Say
                 (Env,
                  JSON.To_String
                    (States.To_JSON (States.Initial (Item, Input))) & LF);
               return 0;
            end;
         end if;

         declare
            Run_State : States.State;
            Output    : JSON.Value;
         begin
            Read_Source (Env, To_String (State_Path), "--state", Text, Ok);
            if not Ok then
               return 1;
            end if;
            declare
               Read : constant States.State_Results.Result :=
                 States.Parse (To_String (Text));
            begin
               if not States.State_Results.Is_Success (Read) then
                  Complain
                    (Env,
                     "error: --state is not a run state: "
                     & To_String (States.State_Results.Error (Read)) & LF);
                  return 1;
               end if;
               Run_State := States.State_Results.Value (Read);
            end;
            if To_String (Run_State.Pipeline) /= To_String (Name) then
               Complain
                 (Env,
                  "error: --state is a run of '"
                  & To_String (Run_State.Pipeline) & "', not of '"
                  & To_String (Name) & "'" & LF);
               return 1;
            elsif Run_State.Status /= States.Running then
               Complain
                 (Env, "error: the run is over, so there is no step to give "
                  & "a result for" & LF);
               return 1;
            end if;

            Read_Source (Env, To_String (Result_Path), "--result", Text, Ok);
            if not Ok then
               return 1;
            end if;
            declare
               Read : constant Envelopes.Envelope_Results.Result :=
                 Envelopes.Parse (To_String (Text));
            begin
               if not Envelopes.Envelope_Results.Is_Success (Read) then
                  Complain
                    (Env,
                     "error: --result is not a valid result: "
                     & To_String (Envelopes.Envelope_Results.Error (Read))
                     & LF);
                  return 1;
               end if;
               Output :=
                 Envelopes.To_JSON (Envelopes.Envelope_Results.Value (Read));
            end;

            Say
              (Env,
               JSON.To_String
                 (States.To_JSON
                    (Engine.Hold_To_Ceiling
                       (Engine.Advance (Item, Run_State, Output),
                        Configs.Config_Results.Value (Settled)))) & LF);
            return 0;
         end;
      end;
   end Run;

end Synapse.Pipeline.Commands.Next;
