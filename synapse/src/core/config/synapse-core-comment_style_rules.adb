package body Synapse.Core.Comment_Style_Rules is

   function Lower (C : Character) return Character is
     (if C in 'A' .. 'Z' then Character'Val (Character'Pos (C) + 32) else C);

   function Contains_Ignoring_Case (Haystack, Needle : String) return Boolean
   is
   begin
      if Needle'Length > Haystack'Length then
         return False;
      end if;
      for Start in Haystack'First .. Haystack'Last - Needle'Length + 1 loop
         declare
            Same : Boolean := True;
         begin
            for K in 0 .. Needle'Length - 1 loop
               if Lower (Haystack (Start + K)) /= Needle (Needle'First + K)
               then
                  Same := False;
                  exit;
               end if;
            end loop;
            if Same then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Contains_Ignoring_Case;

   function Historian_Plague_Phrase (Text : String) return String is
     (if Contains_Ignoring_Case (Text, "no longer") then "no longer"
      elsif Contains_Ignoring_Case (Text, "used to") then "used to"
      elsif Contains_Ignoring_Case (Text, "any more") then "any more" else "");

end Synapse.Core.Comment_Style_Rules;
