with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Skills;

package body Synapse.Pipeline.Instructions is

   use Ada.Strings.Unbounded;
   use type Resolved.Instruction_Kind;

   LF : constant Character := Character'Val (10);

   procedure Text_Of
     (Files       : File_System.File_System'Class;
      Skill_Roots : Search_Paths.Root_Vectors.Vector;
      Item        : Resolved.Instruction;
      Text        : out Unbounded_String;
      Directory   : out Unbounded_String;
      Problem     : out Unbounded_String)
   is
   begin
      Text := Null_Unbounded_String;
      Directory := Null_Unbounded_String;
      Problem := Null_Unbounded_String;
      if not Item.Present then
         return;
      elsif Item.Kind = Resolved.Prompt_Text then
         Text := Item.Text;
         return;
      end if;
      declare
         Name  : constant String := To_String (Item.Text);
         Found : constant Synapse.Core.Optional_Text.Option :=
           Skills.Find (Files, Skill_Roots, Name);
      begin
         if not Found.Found then
            Problem := To_Unbounded_String
              ("skill '" & Name & "' was not found in "
               & Skills.Searched (Skill_Roots));
            return;
         end if;
         declare
            Where   : constant String := To_String (Found.Value);
            Content : constant File_System.Maybe_Content :=
              Files.Read (Where & "/SKILL.md");
         begin
            if not Content.Found then
               Problem := To_Unbounded_String
                 ("skill '" & Name & "' has no readable SKILL.md in "
                  & Where);
               return;
            end if;
            Directory := Found.Value;
            Text := To_Unbounded_String
              ("Follow this skill. Its files are in " & Where & "." & LF & LF)
              & Content.Value;
         end;
      end;
   end Text_Of;

end Synapse.Pipeline.Instructions;
