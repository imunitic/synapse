
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Node_Format;

package body Synapse.Commands.Node_Lists is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Slug (Number : Positive) return String is
      Digits_Text : constant String := Core.Decimal_Image.Image (Number);
   begin
      return
        [1 .. Natural'Max (0, 3 - Digits_Text'Length) => '0'] & Digits_Text;
   end Slug;

   function Blank (C : Character) return Boolean is
     (C in ' ' | ASCII.HT | ASCII.CR);

   function Read (Dir : String) return Node_Vectors.Vector is
      Result : Node_Vectors.Vector;
   begin
      for N in 1 .. Core.Node_Format.Max_Nodes loop
         declare
            Title_Text : Unbounded_String;
            List_Text  : Unbounded_String;
            Have       : Boolean;
            Base       : constant String := Dir & "/" & Slug (N);
         begin
            Synapse.Commands.Graph_Support.Read_File
              (Base & ".title", 64 * 1_024, Title_Text, Have);
            if Have then
               declare
                  Whole : constant String := To_String (Title_Text);
                  Stop  : Natural         := Whole'Last;
                  First : Positive        := Whole'First;
               begin
                  for I in Whole'Range loop
                     if Whole (I) = LF then
                        Stop := I - 1;
                        exit;
                     end if;
                  end loop;
                  while First <= Stop and then Blank (Whole (First)) loop
                     First := First + 1;
                  end loop;
                  while Stop >= First and then Blank (Whole (Stop)) loop
                     Stop := Stop - 1;
                  end loop;
                  if Stop >= First then
                     Synapse.Commands.Graph_Support.Read_File
                       (Base & ".txt", 64 * 1_024 * 1_024, List_Text, Have);
                     if Have then
                        declare
                           Item  : Node            :=
                             (Number   => N,
                              Title    =>
                                To_Unbounded_String (Whole (First .. Stop)),
                              Txt_Path => To_Unbounded_String (Base & ".txt"),
                              Paths    => <>, Files => 0);
                           Text  : constant String := To_String (List_Text);
                           Start : Positive        := Text'First;
                        begin
                           for I in Text'First .. Text'Last + 1 loop
                              if I > Text'Last or else Text (I) = LF then
                                 declare
                                    Last : Natural := I - 1;
                                 begin
                                    if Last >= Start
                                      and then Text (Last) = ASCII.CR
                                    then
                                       Last := Last - 1;
                                    end if;
                                    if Last >= Start then
                                       Item.Paths.Append
                                         (To_Unbounded_String
                                            (Text (Start .. Last)));
                                    end if;
                                    if not
                                      (for all K in Start .. I - 1 =>
                                         Blank (Text (K)))
                                    then
                                       Item.Files := Item.Files + 1;
                                    end if;
                                 end;
                                 Start := I + 1;
                              end if;
                           end loop;
                           Result.Append (Item);
                        end;
                     end if;
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Read;

end Synapse.Commands.Node_Lists;
