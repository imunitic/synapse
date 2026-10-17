package body Synapse.Commands is

   procedure Say (Env : Environment; Text : String) is
   begin
      Env.Console.Write_Out (Text);
   end Say;

   procedure Complain (Env : Environment; Text : String) is
   begin
      Env.Console.Write_Err (Text);
   end Complain;

   function Usage_Error
     (Env : Environment; Usage_Text : String) return Exit_Code
   is
   begin
      Complain (Env, Usage_Text);
      return 2;
   end Usage_Error;

end Synapse.Commands;
