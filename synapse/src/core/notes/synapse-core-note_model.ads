with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;

--  A note as schema validation sees it: typed frontmatter fields, the order
--  fields appear in, the headings of the body, and the data tree that a
--  schema's rules are evaluated against.

package Synapse.Core.Note_Model is

   use Ada.Strings.Unbounded;

   ---------------------------------------------------------------------------
   --  What a write is doing
   ---------------------------------------------------------------------------

   type Mode is (Create, Update, Migration);

   --  The text of one vocabulary file, named by its stem: no directory and no
   --  extension.
   type Vocabulary_Source is record
      Stem    : Unbounded_String;
      Content : Unbounded_String;
   end record;

   package Vocabulary_Vectors is new
     Ada.Containers.Vectors (Positive, Vocabulary_Source);

   type Context is record
      Mode               : Note_Model.Mode := Update;

      --  The note's text before the write, when there is one.
      Has_Existing       : Boolean := False;
      Existing           : Unbounded_String;

      --  The identity another note already holds, found by the scan that
      --  runs on create and migration; none when the identity is unique.
      Has_Duplicate      : Boolean := False;
      Duplicate_Identity : Unbounded_String;

      --  The vocabulary files the schema's rules read.
      Vocabularies       : Vocabulary_Vectors.Vector;
   end record;

   ---------------------------------------------------------------------------
   --  Typed frontmatter fields
   ---------------------------------------------------------------------------

   package Text_Vectors is new
     Ada.Containers.Vectors (Positive, Unbounded_String);

   type Field_Kind is
     (String_Field, Integer_Field, Boolean_Field, List_Field, Invalid_Field);

   type Field_Value (Kind : Field_Kind := Invalid_Field) is record
      case Kind is
         when String_Field =>
            Text : Unbounded_String;

         when Integer_Field =>
            Number : Long_Long_Integer;

         when Boolean_Field =>
            Flag : Boolean;

         when List_Field =>
            Items : Text_Vectors.Vector;

         when Invalid_Field =>
            null;
      end case;
   end record;

   type Lookup is record
      Found     : Boolean := False;
      Duplicate : Boolean := False;  --  the key appears more than once
      Value     : Field_Value;       --  of the first occurrence
   end record;

   --  The top-level field Name of Note's frontmatter. A value is:
   --  * a quoted string, without its quotes;
   --  * `true` or `false`, a boolean;
   --  * an optional minus and digits that fit, an integer;
   --  * `[a, b]`, a list, split at commas outside quotes;
   --  * empty and followed by indented `- item` lines, a block list, and
   --    empty with none, an empty list;
   --  * any other text, a string.
   --  A trailing ` #` comment is dropped. An unterminated quote or flow
   --  list, or a block entry that is not `- item` (a mapping inside a list,
   --  say), is invalid. Lines that start with a space, tab or `#` are not
   --  keys.
   function Lookup_Field (Note, Name : String) return Lookup;

   --  Whether the value has the schema type `Type_Name`: `string` and
   --  `timestamp` are strings, then `list`, `integer`, `boolean`, and `any`
   --  is every value.
   function Has_Type (Value : Field_Value; Type_Name : String) return Boolean;

   function Values_Equal (A, B : Field_Value) return Boolean;

   ---------------------------------------------------------------------------
   --  Field order
   ---------------------------------------------------------------------------

   type Field_Position is record
      Key        : Unbounded_String;
      Line_Start : Natural;  --  byte offset of the key's line in the note
   end record;

   package Position_Vectors is new
     Ada.Containers.Vectors (Positive, Field_Position);

   --  Every top-level key of the frontmatter in file order, first occurrence
   --  only. Empty when the note has no frontmatter.
   function Field_Positions (Note : String) return Position_Vectors.Vector;

   ---------------------------------------------------------------------------
   --  Headings
   ---------------------------------------------------------------------------

   type Heading is record
      Level         : Positive;
      Title         : Unbounded_String;
      Line_Start    : Natural;
      Content_Start : Natural;
      Content_End   : Natural;
   end record;

   type Heading_Array is array (Positive range <>) of Heading;

   --  The Markdown headings of Markdown, in order: a line at column zero of
   --  one to six `#` and a space, outside fenced code. A heading's content
   --  runs to the next heading of its level or a shallower one, or to the
   --  end of the text.
   function Collect_Headings (Markdown : String) return Heading_Array;

   ---------------------------------------------------------------------------
   --  JSON views
   ---------------------------------------------------------------------------

   --  An object of the note's top-level frontmatter fields, every value a
   --  string or a list of strings. See the task note for the exact rules;
   --  an empty value with no list below it is an empty list, and a repeated
   --  key keeps its last value.
   function Frontmatter_As_JSON (Note : String) return JSON.Value;

   --  The entries of a vocabulary file, one per line, as a list of strings: a
   --  `key=value` line contributes its value, any other line itself; blank
   --  lines and comments are skipped.
   function Vocabulary_Items (Content : String) return JSON.Value;

   --  The value a schema's `checks:` and `lints:` rules read:
   --    path, filename.stem, frontmatter, body.prose, body.section_names,
   --    is_create, id_is_unique, created_epoch, updated_epoch, vocabularies.
   --  `id_is_unique` is null unless the write creates or migrates the note.
   function Data_Tree
     (Path : String; Note : String; Ctx : Context) return JSON.Value;

end Synapse.Core.Note_Model;
