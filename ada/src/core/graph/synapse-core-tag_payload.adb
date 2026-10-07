with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces;

with Synapse.Core.Little_Endian;

package body Synapse.Core.Tag_Payload is

   use Little_Endian;
   use type Interfaces.Unsigned_32;

   function Encode_One (Item : Graph_Model.Tag) return String is
     (Character'Val (Graph_Model.Role'Pos (Item.Which)) &
      Put_U32 (U32 (Item.Line)) & Put_U16 (U16 (Length (Item.Name))) &
      To_String (Item.Name) & Put_U16 (U16 (Length (Item.Kind))) &
      To_String (Item.Kind) & Put_U32 (U32 (Length (Item.Expression))) &
      To_String (Item.Expression));

   function Encode (Tags : Tag_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for Item of Tags loop
         Append (Result, Encode_One (Item));
      end loop;
      return To_String (Result);
   end Encode;

   procedure Next
     (Bytes : String; Position : in out Integer; Result : out Maybe_Tag)
   is
      Here : Integer := Position;

      --  Whether Count more bytes are there.
      function Has (Count : Natural) return Boolean is
        (Here >= Bytes'First and then Count <= Bytes'Last - Here + 1);
   begin
      Result := (Found => False);
      if Position > Bytes'Last or else not Has (1 + 4 + 2) then
         return;
      end if;

      declare
         Role_Byte : constant Natural := Character'Pos (Bytes (Here));
         Line      : constant U32     := Get_U32 (Bytes, Here + 1);
      begin
         if Role_Byte > 1 or else Line > U32 (Natural'Last) then
            return;
         end if;
         Here := Here + 5;

         declare
            Name_Length : constant Natural := Natural (Get_U16 (Bytes, Here));
         begin
            Here := Here + 2;
            if not Has (Name_Length + 2) then
               return;
            end if;
            declare
               Name : constant String :=
                 Bytes (Here .. Here + Name_Length - 1);
            begin
               Here := Here + Name_Length;
               declare
                  Kind_Length : constant Natural :=
                    Natural (Get_U16 (Bytes, Here));
               begin
                  Here := Here + 2;
                  if not Has (Kind_Length + 4) then
                     return;
                  end if;
                  declare
                     Kind : constant String :=
                       Bytes (Here .. Here + Kind_Length - 1);
                  begin
                     Here := Here + Kind_Length;
                     declare
                        Expr_Length : constant U32 := Get_U32 (Bytes, Here);
                     begin
                        Here := Here + 4;
                        if Expr_Length > U32 (Natural'Last)
                          or else not Has (Natural (Expr_Length))
                        then
                           return;
                        end if;
                        Result   :=
                          (Found => True,
                           Value =>
                             (Name       => To_Unbounded_String (Name),
                              Kind       => To_Unbounded_String (Kind),
                              Which      => Graph_Model.Role'Val (Role_Byte),
                              Line       => Natural (Line),
                              Expression =>
                                To_Unbounded_String
                                  (Bytes
                                     (Here ..
                                          Here + Natural (Expr_Length) - 1))));
                        Position := Here + Natural (Expr_Length);
                     end;
                  end;
               end;
            end;
         end;
      end;
   end Next;

   function Decode (Bytes : String) return Tag_Vectors.Vector is
      Result   : Tag_Vectors.Vector;
      Position : Integer := Bytes'First;
      Item     : Maybe_Tag;
   begin
      loop
         Next (Bytes, Position, Item);
         exit when not Item.Found;
         Result.Append (Item.Value);
      end loop;
      return Result;
   end Decode;

end Synapse.Core.Tag_Payload;
