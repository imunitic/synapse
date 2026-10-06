package body Synapse.Core.Docstring_Overrides is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Is_Whitespace (C : Character) return Boolean is
     (C in ' ' | Character'Val (9) .. Character'Val (13));

   function Single_Node_Type (Source : String) return Maybe_Text is
      Open : Natural := 0;
   begin
      for I in Source'Range loop
         if Source (I) = '(' then
            Open := I;
            exit;
         end if;
      end loop;
      if Open = 0 then
         return (Found => False);
      end if;
      declare
         First : constant Integer := Open + 1;
         Stop  : Integer          := Source'Last + 1;
      begin
         for I in First .. Source'Last loop
            if Source (I) in ')' | '@' or else Is_Whitespace (Source (I)) then
               Stop := I;
               exit;
            end if;
         end loop;
         if Stop = First then
            return (Found => False);
         end if;
         return
           (Found => True,
            Text  => To_Unbounded_String (Source (First .. Stop - 1)));
      end;
   end Single_Node_Type;

   function Comment_Type (Source : String) return String is
      Named : constant Maybe_Text := Single_Node_Type (Source);
   begin
      return
        (if Named.Found then To_String (Named.Text) else Default_Comment_Type);
   end Comment_Type;

   function Declaration_Kinds (Source : String) return Text_Lists.Vector is
      Result : Text_Lists.Vector;
      Start  : Integer := Source'First;
   begin
      while Start <= Source'Last + 1 loop
         declare
            Stop : Integer := Start;
         begin
            while Stop <= Source'Last and then Source (Stop) /= LF loop
               Stop := Stop + 1;
            end loop;
            declare
               Named : constant Maybe_Text :=
                 Single_Node_Type (Source (Start .. Stop - 1));
            begin
               if Named.Found then
                  Result.Append (Named.Text);
               end if;
            end;
            Start := Stop + 1;
         end;
      end loop;
      return Result;
   end Declaration_Kinds;

end Synapse.Core.Docstring_Overrides;
