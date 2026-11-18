package body Synapse.Pipeline.Id_Claims is

   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;

   function Is_Valid (Id : String) return Boolean is
     (Id'Length in 1 .. 64
      and then (for all C of Id =>
                  C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-'));

   function Take_Named
     (Store : in out Registry_Store.Store'Class; Id : String)
      return Named_Result is
   begin
      case Store.Create (Id) is
         when Registry_Store.Created =>
            return Named_Claimed;

         when Registry_Store.Already_Exists =>
            return Named_Taken;

         when Registry_Store.Failed =>
            return Named_Failed;
      end case;
   end Take_Named;

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
