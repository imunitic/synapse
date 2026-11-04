package body Synapse.Pipeline.Id_Claims is

   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;

   function Take
     (Store : in out Registry_Store.Store'Class;
      Draw  : not null access function return String) return Claim
   is
      Result : Claim;
   begin
      for Try in 1 .. Largest_Tries loop
         declare
            Id : constant String := Draw.all;
         begin
            Result.Id := To_Unbounded_String (Id);
            case Store.Create (Id) is
               when Registry_Store.Created =>
                  Result.Registered := True;
                  return Result;

               when Registry_Store.Failed =>
                  return Result;

               when Registry_Store.Already_Exists =>
                  null;
            end case;
         end;
      end loop;
      return Result;
   end Take;

end Synapse.Pipeline.Id_Claims;
