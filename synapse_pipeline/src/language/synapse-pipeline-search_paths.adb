with GNAT.OS_Lib;

package body Synapse.Pipeline.Search_Paths is

   use Ada.Strings.Unbounded;

   function Setting
     (V : Synapse.Ports.Variables.Variables'Class; Name : String)
      return String
   is
      Found : constant Synapse.Ports.Variables.Maybe_Value := V.Get (Name);
   begin
      if Found.Found then
         return To_String (Found.Value);
      end if;
      return "";
   end Setting;

   function Make_Root (Path : String; Required : Boolean) return Root is
     (Path => To_Unbounded_String (Path), Required => Required);

   function Config_Directory
     (V : Synapse.Ports.Variables.Variables'Class) return String
   is
      Xdg  : constant String := Setting (V, "XDG_CONFIG_HOME");
      Home : constant String := Setting (V, "HOME");
   begin
      if Xdg /= "" then
         return Xdg & "/synapse-pipeline";
      elsif Home /= "" then
         return Home & "/.config/synapse-pipeline";
      end if;
      return "";
   end Config_Directory;

   function Definition_Roots
     (V : Synapse.Ports.Variables.Variables'Class) return Root_Vectors.Vector
   is
      Result : Root_Vectors.Vector;
      Base   : constant String := Config_Directory (V);
      Listed : constant String := Setting (V, Path_Variable);
      Start  : Positive := Listed'First;
   begin
      if Base /= "" then
         Result.Append (Make_Root (Base, Required => False));
      end if;
      for I in Listed'First .. Listed'Last + 1 loop
         if I > Listed'Last or else Listed (I) = GNAT.OS_Lib.Path_Separator
         then
            if I > Start then
               Result.Append (Make_Root (Listed (Start .. I - 1), True));
            end if;
            Start := I + 1;
         end if;
      end loop;
      return Result;
   end Definition_Roots;

   function Skill_Roots
     (V : Synapse.Ports.Variables.Variables'Class) return Root_Vectors.Vector
   is
      Result : Root_Vectors.Vector;
      Base   : constant String := Config_Directory (V);
   begin
      if Base /= "" then
         Result.Append (Make_Root (Base & "/skills", Required => False));
      end if;
      return Result;
   end Skill_Roots;

end Synapse.Pipeline.Search_Paths;
