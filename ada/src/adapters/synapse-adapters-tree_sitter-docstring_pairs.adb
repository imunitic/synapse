with Ada.Directories;
with Ada.IO_Exceptions;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.Docstring_Overrides;

package body Synapse.Adapters.Tree_Sitter.Docstring_Pairs is

   package Overrides renames Synapse.Core.Docstring_Overrides;

   LF : constant Character := Character'Val (10);

   --  A declaration has a `name` field; the extra kinds are the verified
   --  exceptions.
   function Is_Declaration
     (N : Node; Extra_Kinds : Core.Text_Lists.Vector) return Boolean
   is
   begin
      if not Is_Null (Child_By_Field (N, "name")) then
         return True;
      end if;
      for Extra of Extra_Kinds loop
         if To_String (Extra) = Kind (N) then
            return True;
         end if;
      end loop;
      return False;
   end Is_Declaration;

   function Texts_Fit
     (Source : String; First_Comment, Last_Comment, Decl : Node)
      return Boolean is
     (Lies_Within (First_Comment, Source)
      and then Lies_Within (Last_Comment, Source)
      and then Lies_Within (Decl, Source));

   procedure Emit
     (Into : in out Pair_Vectors.Vector; Parent : Node; First : Positive;
      Last :        Positive; Decl : Node; Source : String)
   is
      First_Comment : constant Node := Named_Child (Parent, First);
      Last_Comment  : constant Node := Named_Child (Parent, Last);
   begin
      if not Texts_Fit (Source, First_Comment, Last_Comment, Decl) then
         return;
      end if;
      declare
         Docstring : Unbounded_String;
         Decl_Text : constant String := Text_Of (Decl, Source);
         Line_End  : Natural         := Decl_Text'Last + 1;
      begin
         for Index in First .. Last loop
            declare
               Comment : constant Node := Named_Child (Parent, Index);
            begin
               if not Lies_Within (Comment, Source) then
                  return;
               end if;
               if Index /= First then
                  Append (Docstring, LF);
               end if;
               Append (Docstring, Text_Of (Comment, Source));
            end;
         end loop;
         for I in Decl_Text'Range loop
            if Decl_Text (I) = LF then
               Line_End := I;
               exit;
            end if;
         end loop;
         --  Tree-sitter rows are 0-based; the index stores 1-based inclusive
         --  lines.
         Into.Append
           (Pair'
              (Kind                 => To_Unbounded_String (Kind (Decl)),
               Name                 =>
                 To_Unbounded_String
                   (Decl_Text (Decl_Text'First .. Line_End - 1)),
               Docstring_Text       => Docstring,
               Decl_Text            => To_Unbounded_String (Decl_Text),
               Docstring_Start_Line => Start_Point (First_Comment).Row + 1,
               Docstring_End_Line   => End_Point (Last_Comment).Row + 1,
               Decl_Start_Line      => Start_Point (Decl).Row + 1,
               Decl_End_Line        => End_Point (Decl).Row + 1));
      end;
   end Emit;

   --  The runs of adjacent comments among the named children of Parent, each
   --  paired with the declaration directly under it when there is one.
   procedure Pair_Children
     (Into : in out Pair_Vectors.Vector; Parent : Node; Source : String;
      Comment_Type :        String; Extra_Kinds : Core.Text_Lists.Vector)
   is
      Count : constant Natural := Named_Child_Count (Parent);
      Index : Natural          := 1;
   begin
      while Index <= Count loop
         if Kind (Named_Child (Parent, Index)) /= Comment_Type then
            Index := Index + 1;
         else
            declare
               Run_End : Natural := Index;
            begin
               while Run_End < Count loop
                  declare
                     Current : constant Node := Named_Child (Parent, Run_End);
                     Next : constant Node := Named_Child (Parent, Run_End + 1);
                  begin
                     exit when Kind (Next) /= Comment_Type;
                     exit when Start_Point (Next).Row /=
                       End_Point (Current).Row + 1;
                     Run_End := Run_End + 1;
                  end;
               end loop;

               if Run_End < Count then
                  declare
                     Decl : constant Node := Named_Child (Parent, Run_End + 1);
                     Last_Comment : constant Node :=
                       Named_Child (Parent, Run_End);
                  begin
                     if Start_Point (Decl).Row =
                       End_Point (Last_Comment).Row + 1
                       and then Kind (Decl) /= Comment_Type
                       and then Is_Declaration (Decl, Extra_Kinds)
                     then
                        Emit (Into, Parent, Index, Run_End, Decl, Source);
                     end if;
                  end;
               end if;
               Index := Run_End + 1;
            end;
         end if;
      end loop;
   end Pair_Children;

   package Node_Stacks is new Ada.Containers.Vectors (Positive, Node);

   function Find_Pairs
     (Lang        : Language; Source : String; Comment_Type : String;
      Extra_Kinds : Core.Text_Lists.Vector) return Pair_Results.Result
   is
      Reader   : Parser;
      Accepted : Boolean;
   begin
      Set_Language (Reader, Lang, Accepted);
      if not Accepted then
         return Pair_Results.Failure (Language_Rejected);
      end if;
      declare
         Parsed : constant Tree := Parse (Reader, Source);
      begin
         if Is_Null (Parsed) then
            return Pair_Results.Failure (Not_Parsed);
         end if;
         declare
            Found : Pair_Vectors.Vector;
            Stack : Node_Stacks.Vector;
         begin
            --  A stack stands in for recursion, so a deeply nested file cannot
            --  exhaust the call stack: a node's pairs first, then the nodes
            --  below it left to right.
            Stack.Append (Root (Parsed));
            while not Stack.Is_Empty loop
               declare
                  Current : constant Node := Stack.Last_Element;
               begin
                  Stack.Delete_Last;
                  Pair_Children
                    (Found, Current, Source, Comment_Type, Extra_Kinds);
                  for I in reverse 1 .. Named_Child_Count (Current) loop
                     Stack.Append (Named_Child (Current, I));
                  end loop;
               end;
            end loop;
            return Pair_Results.Success (Found);
         end;
      end;
   end Find_Pairs;

   --  The text of the override file for Extension, or none.
   function Override_Text
     (Override_Dir : Core.Grammar_Registry.Maybe_Text; Extension : String;
      Suffix       : String; Found : out Boolean) return String
   is
   begin
      Found := False;
      if not Override_Dir.Found then
         return "";
      end if;
      declare
         Path : constant String :=
           To_String (Override_Dir.Value) & "/" & Extension & Suffix;
      begin
         if not Ada.Directories.Exists (Path) then
            return "";
         end if;
         declare
            Text : constant String := File_Bytes.Read (Path, 4_096);
         begin
            Found := True;
            return Text;
         end;
      end;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error
        | File_Bytes.Too_Large =>
         Found := False;
         return "";
   end Override_Text;

   function Comment_Type_Name
     (Override_Dir : Core.Grammar_Registry.Maybe_Text; Extension : String)
      return String
   is
      Found : Boolean;
      Text  : constant String :=
        Override_Text (Override_Dir, Extension, ".comments.scm", Found);
   begin
      return
        (if Found then Overrides.Comment_Type (Text)
         else Overrides.Default_Comment_Type);
   end Comment_Type_Name;

   function Declaration_Overrides
     (Override_Dir : Core.Grammar_Registry.Maybe_Text; Extension : String)
      return Core.Text_Lists.Vector
   is
      Found : Boolean;
      Text  : constant String :=
        Override_Text (Override_Dir, Extension, ".declarations.scm", Found);
      None  : Core.Text_Lists.Vector;
   begin
      return (if Found then Overrides.Declaration_Kinds (Text) else None);
   end Declaration_Overrides;

end Synapse.Adapters.Tree_Sitter.Docstring_Pairs;
