--  Frontmatter operations that build lists or need to raise: scalars as a
--  YAML reader sees them, one-field writes, and tag edits. Everything here is
--  built on the proved scanning and splicing in Synapse.Core.Frontmatter.

with Ada.Strings.Unbounded;

package Synapse.Core.Frontmatter.Edit with SPARK_Mode => Off is

   --  Largest scalar and list that Set_Scalar and Set_List accept: quoting can
   --  double a string, and the rendered line must still fit Max_Value_Length.
   Max_Scalar_Length : constant := Max_Value_Length / 2 - 1;
   Max_List_Text     : constant := 2**17;
   Max_List_Items    : constant := 2**12;

   type String_Array is
     array (Positive range <>) of Ada.Strings.Unbounded.Unbounded_String;

   type Maybe_Text (Found : Boolean := False) is record
      case Found is
         when True =>
            Item : Ada.Strings.Unbounded.Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  The note has no frontmatter block to write into.
   No_Frontmatter : exception;

   --  A top-level scalar as a YAML reader sees it: a double-quoted value has
   --  its escapes undone (`\\`, `\"`, `\n`, `\r`), an unquoted value is
   --  returned as written.
   function Scalar (Note, Key : String) return Maybe_Text
   with Pre => Note'Last < Positive'Last and then Key'Last < Positive'Last;

   --  Note with Key set to Value, quoted when it needs quotes. Raises
   --  No_Frontmatter when the note has no frontmatter.
   function Set_Scalar (Note, Key, Value : String) return String
   with
     Pre =>
       Note'Last < Positive'Last
       and then Note'Length <= Max_Note_Length
       and then Key'Last < Positive'Last
       and then Key'Length <= Max_Key_Length
       and then Value'Last < Positive'Last
       and then Value'Length <= Max_Scalar_Length;

   function Total_Length (Items : String_Array) return Natural;

   --  Note with Key set to a flow sequence of Items, `[a, b]`, each quoted
   --  only when it needs quotes. Raises No_Frontmatter when the note has no
   --  frontmatter.
   function Set_List (Note, Key : String; Items : String_Array) return String
   with
     Pre =>
       Note'Last < Positive'Last
       and then Note'Length <= Max_Note_Length
       and then Key'Last < Positive'Last
       and then Key'Length <= Max_Key_Length
       and then Items'Length <= Max_List_Items
       and then Total_Length (Items) <= Max_List_Text;

   --  The items of a `tags: [a, b]` flow sequence, blanks trimmed and one
   --  pair of quotes removed from each. No items when `tags` is absent, `[]`,
   --  or not written as a flow sequence.
   function Parse_Tags (Note : String) return String_Array
   with Pre => Note'Last < Positive'Last;

   --  Note with Tag appended to `tags`; Note itself when it already has Tag.
   function Add_Tag (Note, Tag : String) return String
   with
     Pre =>
       Note'Last < Positive'Last
       and then Note'Length <= Max_Note_Length
       and then Tag'Length <= Max_List_Text / 2;

   --  Note without Tag in `tags`, leaving `tags: []` when it was the last;
   --  Note itself when Tag is not there.
   function Remove_Tag (Note, Tag : String) return String
   with
     Pre =>
       Note'Last < Positive'Last
       and then Note'Length <= Max_Note_Length;

end Synapse.Core.Frontmatter.Edit;
