with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Conf_Files;
with Synapse.Commands.Context;
with Synapse.Commands.Vault_Support;
with Synapse.Commands.Vault_Usage;
with Synapse.Core.Float_Image;
with Synapse.Core.JSON;
with Synapse.Core.Node_Query;
with Synapse.Core.Text_Search;
with Synapse.Core.Vault_Query;
with Synapse.Core.Words;
with Synapse.Ports.Search_Filtered;
with Synapse.Ports.Store;

package body Synapse.Commands.Vault_Search is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;
   package Port renames Synapse.Ports.Store;
   package Support renames Synapse.Commands.Vault_Support;

   Prog : constant String    := "synapse-vault";
   LF   : constant Character := Character'Val (10);

   function Trimmed (Text : String) return String is
     (Ada.Strings.Fixed.Trim
        (Text, Ada.Strings.Maps.To_Set (" " & ASCII.HT),
         Ada.Strings.Maps.To_Set (" " & ASCII.HT)));

   --  The text a column holds for a value: a string bare, anything else as
   --  compact JSON, so a list or a missing field still fills one column.
   function Column (V : JSON.Value) return String is
     (if JSON.Kind_Of (V) = JSON.JSON_String then JSON.As_String (V)
      else JSON.To_String (V));

   function Run_Search
     (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Fields : Lists.Vector;
      I      : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Arg = "-h" or else Arg = "--help" then
               Complain (Env, Vault_Usage.Search);
               return 0;
            elsif Arg = "--fields" then
               if I = Natural (Args.Length) then
                  return Usage_Error (Env, Vault_Usage.Search);
               end if;
               I := I + 1;
               declare
                  Raw   : constant String := To_String (Args (I));
                  Start : Positive        := Raw'First;
               begin
                  for J in Raw'First .. Raw'Last + 1 loop
                     if J > Raw'Last or else Raw (J) = ',' then
                        declare
                           Field : constant String :=
                             Trimmed (Raw (Start .. J - 1));
                        begin
                           if Field'Length > 0 then
                              Fields.Append (To_Unbounded_String (Field));
                           end if;
                        end;
                        Start := J + 1;
                     end if;
                  end loop;
               end;
            else
               return Usage_Error (Env, Vault_Usage.Search);
            end if;
         end;
         I := I + 1;
      end loop;

      declare
         Vault : Unbounded_String;
         Found : Boolean;
      begin
         Support.Find_Vault (Env, Prog, Vault, Found);
         if not Found then
            return 1;
         end if;
         declare
            Rule   : constant String            := Env.Console.Read_Stdin;
            Parsed : constant JSON.Parse_Result := JSON.Parse (Rule);
            Stack  : Support.Store_Resolve.Stack;
            Ok     : Boolean;
         begin
            if not Parsed.Ok then
               Complain (Env, Prog & ": stdin is not valid JSON" & LF);
               return 1;
            end if;
            Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
            if not Ok then
               return 1;
            end if;
            declare
               Rows     : constant Core.Vault_Query.Row_Vectors.Vector :=
                 Core.Vault_Query.Query
                   (Support.Store_Resolve.Store (Stack).all, Parsed.Item,
                    Fields);
               Out_Text : Unbounded_String;
            begin
               for Row of Rows loop
                  Append (Out_Text, Row.Path);
                  for V of Row.Values loop
                     Append (Out_Text, ASCII.HT & Column (V));
                  end loop;
                  Append (Out_Text, LF);
               end loop;
               Say (Env, To_String (Out_Text));
               return 0;
            end;
         exception
            when Port.Store_Failure | Port.Unsafe_Node | Port.Node_Not_Found =>
               Complain (Env, Prog & ": query failed" & LF);
               return 1;
         end;
      end;
   end Run_Search;

   --  The rule `--namespace` stands for: only paths under that graph's
   --  folder, and-ed with the filter on standard input when there is one.
   --  Empty when Namespace could not be written into a JSON string as it is.
   function Namespace_Filter
     (Namespace : String; User : String; Has_User : Boolean) return String
   is
   begin
      for C of Namespace loop
         if C = '"' or else C = '\' or else C < ' ' then
            return "";
         end if;
      end loop;
      declare
         Own : constant String :=
           "{""glob"": [""synapse/" & Namespace &
           "/*"", {""var"": ""path""}]}";
      begin
         return
           (if Has_User then "{""and"": [" & Own & ", " & User & "]}"
            else Own);
      end;
   end Namespace_Filter;

   function Run_Search_Text
     (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Want_Filter : Boolean  := False;
      Has_Space   : Boolean  := False;
      Namespace   : Unbounded_String;
      I           : Positive := 2;
   begin
      if Args.Is_Empty then
         return Usage_Error (Env, Vault_Usage.Search_Text);
      end if;
      declare
         Query : constant String := To_String (Args (1));
      begin
         if Query = "-h" or else Query = "--help" then
            Complain (Env, Vault_Usage.Search_Text);
            return 0;
         end if;
         while I <= Natural (Args.Length) loop
            declare
               Arg : constant String := To_String (Args (I));
            begin
               if Arg = "--path-filter" and then not Want_Filter then
                  Want_Filter := True;
               elsif Arg = "--namespace" and then not Has_Space then
                  if I = Natural (Args.Length) then
                     return Usage_Error (Env, Vault_Usage.Search_Text);
                  end if;
                  I         := I + 1;
                  Namespace := Args (I);
                  Has_Space := True;
               else
                  return Usage_Error (Env, Vault_Usage.Search_Text);
               end if;
            end;
            I := I + 1;
         end loop;

         declare
            Vault : Unbounded_String;
            Found : Boolean;
         begin
            Support.Find_Vault (Env, Prog, Vault, Found);
            if not Found then
               return 1;
            end if;

            if Has_Space
              and then Namespace_Filter (To_String (Namespace), "", False) = ""
            then
               Complain
                 (Env,
                  Prog & ": --namespace expects <repo>@<branch>, got '" &
                  To_String (Namespace) & "'" & LF);
               return 2;
            end if;

            if Has_Space then
               declare
                  Ctx : constant Context.Maybe_Context :=
                    Context.Resolve_Explicit
                      (Env, Prog, To_String (Namespace));
               begin
                  if not Ctx.Found
                    or else not Context.Verify_Namespace (Env, Ctx.Value, Prog)
                  then
                     return 1;
                  end if;
               end;
            end if;

            declare
               User_Text   : constant String  :=
                 (if Want_Filter then Env.Console.Read_Stdin else "");
               Filter_Text : constant String  :=
                 (if Has_Space then
                    Namespace_Filter
                      (To_String (Namespace), User_Text, Want_Filter)
                  else User_Text);
               Needs_Rule  : constant Boolean := Has_Space or else Want_Filter;
            begin
               declare
                  Parsed : constant JSON.Parse_Result :=
                    (if Needs_Rule then JSON.Parse (Filter_Text)
                     else (Ok => True, Item => JSON.Null_Value));
                  Stack  : Support.Store_Resolve.Stack;
                  Ok     : Boolean;
               begin
                  if not Parsed.Ok then
                     Complain (Env, Prog & ": stdin is not valid JSON" & LF);
                     return 1;
                  end if;
                  Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
                  if not Ok then
                     return 1;
                  end if;
                  declare
                     Filter   :
                       constant Synapse.Ports.Search_Filtered.Path_Filter :=
                       (if Needs_Rule then
                          (Found => True, Value => Parsed.Item)
                        else Synapse.Ports.Search_Filtered.No_Filter);
                     Hits     : constant Port.Hit_Vectors.Vector :=
                       Support.Store_Resolve.Search_Filtered
                         (Stack, Query, Filter);
                     Words    : constant Lists.Vector :=
                       Core.Words.Query_Terms
                         (Query,
                          Adapters.Conf_Files.Load_Stopwords (Env.Vars.all));
                     Literal  : Lists.Vector;
                     Out_Text : Unbounded_String;
                     Shown    : Natural := 0;
                  begin
                     Literal.Append (To_Unbounded_String (Query));
                     for Hit of Hits loop
                        exit when Shown = Row_Cap;
                        Shown := Shown + 1;
                        Append
                          (Out_Text,
                           To_String (Hit.Node) & ASCII.HT &
                           Core.Float_Image.Shortest (Hit.Score) & ASCII.HT);
                        declare
                           Text : constant Port.Maybe_Text :=
                             Support.Store_Resolve.Store (Stack).Read
                               (To_String (Hit.Node));
                        begin
                           if Text.Found then
                              declare
                                 Whole      : constant String   :=
                                   To_String (Text.Value);
                                 Prose      : constant String   :=
                                   Core.Node_Query.Body_After_Frontmatter
                                     (Whole);
                                 Before     : constant String   :=
                                   Whole
                                     (Whole'First ..
                                          Whole'Last - Prose'Length);
                                 First_Line : constant Positive :=
                                   1 +
                                   Ada.Strings.Fixed.Count (Before, "" & LF);
                              begin
                                 Append
                                   (Out_Text,
                                    Core.Text_Search.Image
                                      (Core.Text_Search.Match_Ranges
                                         (Prose, First_Line,
                                           (if Words.Is_Empty then Literal
                                           else Words))));
                              end;
                           end if;
                        end;
                        Append (Out_Text, LF);
                     end loop;
                     Say (Env, To_String (Out_Text));
                     return 0;
                  end;
               exception
                  when Port.Store_Failure | Port.Unsafe_Node
                    | Port.Node_Not_Found =>
                     Complain (Env, Prog & ": search failed" & LF);
                     return 1;
               end;
            end;
         end;
      end;
   end Run_Search_Text;

end Synapse.Commands.Vault_Search;
