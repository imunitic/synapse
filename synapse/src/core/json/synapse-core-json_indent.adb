with Ada.Strings.Unbounded;

with Synapse.Core.JSON;

package body Synapse.Core.JSON_Indent is

   use Ada.Strings.Unbounded;
   use type JSON.Kind;

   LF : constant Character := Character'Val (10);

   --  Appends V, nested Depth levels deep, to Text.
   procedure Emit (V : JSON.Value; Depth : Natural; Text : in out Unbounded_String)
   is
      Pad  : constant String (1 .. 2 * (Depth + 1)) := (others => ' ');
      Back : constant String (1 .. 2 * Depth)       := (others => ' ');
   begin
      case JSON.Kind_Of (V) is
         when JSON.JSON_Array =>
            if JSON.Length (V) = 0 then
               Append (Text, "[]");
               return;
            end if;
            Append (Text, "[" & LF);
            for I in 1 .. JSON.Length (V) loop
               Append (Text, Pad);
               Emit (JSON.Element (V, I), Depth + 1, Text);
               Append (Text, (if I = JSON.Length (V) then "" else ",") & LF);
            end loop;
            Append (Text, Back & "]");

         when JSON.JSON_Object =>
            if JSON.Length (V) = 0 then
               Append (Text, "{}");
               return;
            end if;
            Append (Text, "{" & LF);
            for I in 1 .. JSON.Length (V) loop
               Append
                 (Text,
                  Pad & JSON.To_String (JSON.Make_String (JSON.Member_Key (V, I)))
                  & ": ");
               Emit (JSON.Member_At (V, I), Depth + 1, Text);
               Append (Text, (if I = JSON.Length (V) then "" else ",") & LF);
            end loop;
            Append (Text, Back & "}");

         when others =>
            Append (Text, JSON.To_String (V));
      end case;
   end Emit;

   function Indented (V : JSON.Value) return String is
      Text : Unbounded_String;
   begin
      Emit (V, 0, Text);
      return To_String (Text);
   end Indented;

end Synapse.Core.JSON_Indent;
