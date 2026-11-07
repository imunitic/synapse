--  The settings of `synapse.conf`: each key with what it holds, what it is
--  when nothing sets it and whether a variable of the same name can set it.
--  The one list of them, for a command that shows or changes them.

package Synapse.Core.Settings is

   --  What a value is: a path, a comma-separated list of names, a whole
   --  number, or a switch that any non-empty value turns on.
   type Kind is (Path_Kind, List_Kind, Number_Kind, Toggle_Kind);

   type Text_Access is access constant String;

   type Setting is record
      Name        : Text_Access;
      Description : Text_Access;

      --  What the setting is when nothing sets it; empty when it has no value
      --  then.
      Default     : Text_Access;
      What        : Kind;

      --  Nothing works until it is set.
      Required    : Boolean;

      --  A variable of the same name sets it too. Not so for a setting that
      --  only the text of the file carries.
      Environment : Boolean;
   end record;

   Count : constant := 9;

   subtype Index is Positive range 1 .. Count;

   function Item (I : Index) return Setting;

   --  The index of the key, or zero for a name that is not a setting.
   function Find (Name : String) return Natural;

end Synapse.Core.Settings;
