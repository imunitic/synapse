package body Synapse.Core.Schema_YAML_Lexical with SPARK_Mode is

   NUL : constant Character := Character'Val (0);

   function Is_Whitespace (C : Character) return Boolean
   is (C in ' ' | Character'Val (9) | Character'Val (10)
         | Character'Val (11) | Character'Val (12) | Character'Val (13));

   function Comment_Start (Line : String) return Natural is
      Quote   : Character := NUL;
      Escaped : Boolean := False;
   begin
      for I in 0 .. Line'Length - 1 loop
         pragma Loop_Invariant (I < Line'Length);
         declare
            C : constant Character := Line (Line'First + I);
         begin
            if Quote /= NUL then
               if Quote = '"' and then not Escaped and then C = '\' then
                  Escaped := True;
               else
                  if not Escaped and then C = Quote then
                     Quote := NUL;
                  end if;
                  Escaped := False;
               end if;
            elsif C in ''' | '"' then
               Quote := C;
            elsif C = '#'
              and then
                (I = 0
                 or else Is_Whitespace (Line (Line'First + I - 1)))
            then
               return I;
            end if;
         end;
      end loop;
      return Line'Length;
   end Comment_Start;

   function Pair_Colon (Text : String) return Colon is
      Quote   : Character := NUL;
      Escaped : Boolean := False;
      Depth   : Natural := 0;
   begin
      for I in 0 .. Text'Length - 1 loop
         pragma Loop_Invariant (I < Text'Length);
         pragma Loop_Invariant (Depth <= I);
         declare
            C : constant Character := Text (Text'First + I);
         begin
            if Quote /= NUL then
               if Quote = '"' and then not Escaped and then C = '\' then
                  Escaped := True;
               else
                  if not Escaped and then C = Quote then
                     Quote := NUL;
                  end if;
                  Escaped := False;
               end if;
            elsif C in ''' | '"' then
               Quote := C;
            elsif C = '[' then
               Depth := Depth + 1;
            elsif C = ']' then
               if Depth = 0 then
                  return (Found => False, Stray_Bracket => True, Offset => 0);
               end if;
               Depth := Depth - 1;
            elsif C = ':' and then Depth = 0 then
               return (Found => True, Stray_Bracket => False, Offset => I);
            end if;
         end;
      end loop;
      return (Found => False, Stray_Bracket => False, Offset => 0);
   end Pair_Colon;

end Synapse.Core.Schema_YAML_Lexical;
