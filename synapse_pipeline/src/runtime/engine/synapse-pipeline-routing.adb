with Synapse.Pipeline.Guards;

package body Synapse.Pipeline.Routing is

   use Ada.Strings.Unbounded;

   function Route_After
     (Edges  : Resolved.Edge_Vectors.Vector;
      Fired  : Count_Vectors.Vector;
      Step   : String;
      Result : JSON.Value) return Route_Results.Result
   is
   begin
      for I in Edges.First_Index .. Edges.Last_Index loop
         declare
            E     : constant Resolved.Edge := Edges (I);
            Count : constant Natural :=
              (if I <= Fired.Last_Index then Fired (I) else 0);
         begin
            if To_String (E.From) = Step
              and then not (E.Max_Iterations > 0
                            and then Count >= E.Max_Iterations)
            then
               if not E.Has_Guard then
                  return Route_Results.Success ((Fires => True, Edge => I));
               end if;
               declare
                  Held : constant Guards.Guard_Results.Result :=
                    Guards.Holds (E.Guard, Result);
               begin
                  if not Guards.Guard_Results.Is_Success (Held) then
                     return Route_Results.Failure
                       (To_Unbounded_String
                          ("edge " & To_String (E.From) & " -> "
                           & To_String (E.To) & ": "
                           & To_String (Guards.Guard_Results.Error (Held))));
                  elsif Guards.Guard_Results.Value (Held) then
                     return Route_Results.Success
                       ((Fires => True, Edge => I));
                  end if;
               end;
            end if;
         end;
      end loop;
      return Route_Results.Success ((Fires => False));
   end Route_After;

end Synapse.Pipeline.Routing;
