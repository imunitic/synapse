with Ada.Unchecked_Deallocation;

package body Synapse.Core.Unicode.Transforms with SPARK_Mode => Off is

   function Fold (S : String) return String is
      Total : Natural := 0;
      Pos   : Positive := S'First;
   begin
      if S'Length = 0 then
         return S;
      end if;

      while Pos <= S'Last loop
         declare
            Length : constant Natural := UTF8.Sequence_Length (S, Pos);
         begin
            if Length = 0 then
               return S;
            end if;
            Total :=
              Total
              + UTF8.Encoded_Length (Simple_Fold (UTF8.Scalar_At (S, Pos)));
            Pos := Pos + Length;
         end;
      end loop;

      declare
         Result : String (1 .. Total);
         Out_At : Positive := 1;
      begin
         Pos := S'First;
         while Pos <= S'Last loop
            declare
               CP      : UTF8.Scalar_Value;
               Encoded : String (1 .. 4);
               Length  : Natural;
            begin
               UTF8.Decode (S, Pos, CP);
               declare
                  Folded : constant String :=
                    UTF8.Encode (Simple_Fold (CP));
               begin
                  Length := Folded'Length;
                  Encoded (1 .. Length) := Folded;
               end;
               Result (Out_At .. Out_At + Length - 1) := Encoded (1 .. Length);
               Out_At := Out_At + Length;
            end;
         end loop;
         return Result;
      end;
   end Fold;

   type Code_Point_Buffer is access Code_Point_Array;

   procedure Free is new
     Ada.Unchecked_Deallocation
       (Code_Point_Array, Code_Point_Buffer);

   function Normalize_NFC (S : String) return String is
      Count : Natural := 0;
      Pos   : Positive := S'First;
   begin
      if S'Length = 0 then
         return S;
      end if;

      --  Pass 1: validate and size the decomposed sequence.
      while Pos <= S'Last loop
         declare
            Length : constant Natural := UTF8.Sequence_Length (S, Pos);
         begin
            if Length = 0 then
               return S;
            end if;
            Count := Count + Decompose (UTF8.Scalar_At (S, Pos)).Length;
            Pos := Pos + Length;
         end;
      end loop;

      declare
         Buffer : Code_Point_Buffer :=
           new Code_Point_Array (1 .. Count);
         Filled : Natural := 0;
         Output : Natural := 0;
      begin
         --  Pass 2: full canonical decomposition.
         Pos := S'First;
         while Pos <= S'Last loop
            declare
               CP : UTF8.Scalar_Value;
            begin
               UTF8.Decode (S, Pos, CP);
               declare
                  D : constant Decomposition := Decompose (CP);
               begin
                  for K in 1 .. D.Length loop
                     Filled := Filled + 1;
                     Buffer (Filled) := D.Items (K);
                  end loop;
               end;
            end;
         end loop;

         --  Canonical ordering: stable insertion sort of each run of
         --  non-starters by combining class.
         for I in 2 .. Count loop
            if Combining_Class (Buffer (I)) /= 0 then
               declare
                  J : Positive := I;
               begin
                  while J > 1
                    and then Combining_Class (Buffer (J - 1)) /= 0
                    and then Combining_Class (Buffer (J - 1))
                             > Combining_Class (Buffer (J))
                  loop
                     declare
                        Held : constant Code_Point := Buffer (J - 1);
                     begin
                        Buffer (J - 1) := Buffer (J);
                        Buffer (J) := Held;
                     end;
                     J := J - 1;
                  end loop;
               end;
            end if;
         end loop;

         --  Canonical composition, in place: the write index never passes
         --  the read index.
         declare
            Starter    : Positive := 1;
            Last_Class : Natural := Combining_Class (Buffer (1));
         begin
            Output := 1;
            for R in 2 .. Count loop
               declare
                  C  : constant Code_Point := Buffer (R);
                  CC : constant Natural := Combining_Class (C);
                  Pair : constant Composition :=
                    (if Last_Class = 0 or else Last_Class < CC
                     then Compose_Pair (Buffer (Starter), C)
                     else (Found => False));
               begin
                  if Pair.Found then
                     Buffer (Starter) := Pair.Composed;
                  else
                     Output := Output + 1;
                     Buffer (Output) := C;
                     if CC = 0 then
                        Starter := Output;
                     end if;
                     Last_Class := CC;
                  end if;
               end;
            end loop;
         end;

         declare
            Length : Natural := 0;
         begin
            for K in 1 .. Output loop
               Length := Length + UTF8.Encoded_Length (Buffer (K));
            end loop;

            declare
               Result : String (1 .. Length);
               Out_At : Positive := 1;
            begin
               for K in 1 .. Output loop
                  declare
                     Encoded : constant String := UTF8.Encode (Buffer (K));
                  begin
                     Result (Out_At .. Out_At + Encoded'Length - 1) :=
                       Encoded;
                     Out_At := Out_At + Encoded'Length;
                  end;
               end loop;
               Free (Buffer);
               return Result;
            end;
         end;
      end;
   end Normalize_NFC;

   function Normalize_Key (S : String) return String is
   begin
      return Fold (Normalize_NFC (S));
   end Normalize_Key;

end Synapse.Core.Unicode.Transforms;
