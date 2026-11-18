with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Ports.Store;

--  What in a vault currently needs a human decision, in five categories over
--  the `designs/` and `tasks/` folders, each found with the same query engine
--  `vault-search` uses:
--
--    Discussing        design notes whose status is Discussing
--    Ready_Uncompiled  design notes that are Ready and have no compiled task
--    Open_Questions    Ready design notes with open questions, unless their
--                      compiled task is DONE; a compiled task that cannot be
--                      found does not make a note drop out
--    In_Progress       tasks that are TODO or IN-PROGRESS, with the number of
--                      their unchecked items
--    Awaiting_Review   tasks in REVIEW

package Synapse.Core.Vault_Status with
  SPARK_Mode => Off
is

   use Ada.Strings.Unbounded;

   type Category is
     (Discussing, Ready_Uncompiled, Open_Questions, In_Progress,
      Awaiting_Review);

   type Item is record
      Path      : Unbounded_String;
      --  The note's own id, empty when it has none.
      Id        : Unbounded_String;
      Title     : Unbounded_String;
      --  Open_Questions: the title of the compiled task, empty when there is
      --  none.
      Compiled  : Unbounded_String;
      --  In_Progress: the unchecked items of the note.
      Unchecked : Natural := 0;
   end record;

   package Item_Vectors is new Ada.Containers.Vectors (Positive, Item);

   type Report is array (Category) of Item_Vectors.Vector;

   --  Raises the exceptions of Synapse.Ports.Store when the vault cannot be
   --  read.
   function Build (Source : in out Synapse.Ports.Store.Store'Class)
      return Report;

   --  The words a category is called by in JSON, and as a heading.
   function Key (What : Category) return String;
   function Heading (What : Category) return String;

   function Is_Clear (Found : Report) return Boolean;

   --  The report as chat text: a section for each category that has items, a
   --  line for each item led by its id in brackets, or one line saying the
   --  vault is clear.
   function To_Text (Found : Report) return String;

   --  The report as the compact JSON `synapse-status/v1`: every category, in
   --  order, with its items.
   function To_JSON (Found : Report; Vault : String) return String;

   --  The title a note's `Compiled task: [[...]]` line links to, or nothing.
   function Compiled_Task (Content : String) return String;

   --  The lines of Content that are an unchecked list item.
   function Unchecked_Count (Content : String) return Natural;

end Synapse.Core.Vault_Status;
