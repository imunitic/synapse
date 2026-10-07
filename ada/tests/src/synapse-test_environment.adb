with Ada.Strings.Unbounded;

package body Synapse.Test_Environment is

   function Args
     (A1, A2, A3, A4, A5 : String := "") return Synapse.Commands.Lists.Vector
   is
      Result : Synapse.Commands.Lists.Vector;

      procedure Add (Item : String) is
      begin
         if Item /= "" then
            Result.Append (Ada.Strings.Unbounded.To_Unbounded_String (Item));
         end if;
      end Add;
   begin
      Add (A1);
      Add (A2);
      Add (A3);
      Add (A4);
      Add (A5);
      return Result;
   end Args;

end Synapse.Test_Environment;
