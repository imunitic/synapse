with Synapse.Core.Options;

--  How much a step's session may do. A closed set: a name in a definition is
--  checked against it, and each harness adapter says what a level means for
--  that harness.
--
--    Read_Only        look at the working directory and nothing else
--    Workspace_Write  change files in the working directory
--    Full_Access      everything the user running the pipeline can do

package Synapse.Pipeline.Permission_Levels is

   type Level is (Read_Only, Workspace_Write, Full_Access);

   package Level_Options is new Synapse.Core.Options (Level);

   --  The level of a step that names none.
   Default : constant Level := Workspace_Write;

   --  The name as a definition writes it, such as `Read_Only`.
   function Name_Of (Item : Level) return String is
     (case Item is
        when Read_Only       => "Read_Only",
        when Workspace_Write => "Workspace_Write",
        when Full_Access     => "Full_Access");

   --  The level a name stands for, or nothing. Names are exact.
   function Find (Name : String) return Level_Options.Option;

   --  Every name, for saying what was expected.
   function Names return String;

end Synapse.Pipeline.Permission_Levels;
