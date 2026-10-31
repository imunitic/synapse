package body Synapse.Pipeline.System_Inspector is

   use Ada.Strings.Unbounded;

   overriding
   function Endpoint_For
     (T : System_Transport; Work_Directory, Id : String) return String
   is
      pragma Unreferenced (T, Work_Directory);
   begin
      return "\\.\pipe\synapse-pipeline-" & Id;
   end Endpoint_For;

   overriding
   procedure Listen
     (T         : in out System_Transport;
      Endpoint  : String;
      Listening : out Boolean;
      Reason    : out Unbounded_String)
   is
      pragma Unreferenced (Endpoint);
   begin
      T.Listening := False;
      Listening := False;
      Reason :=
        To_Unbounded_String
          ("introspection is not available on this platform yet");
   end Listen;

   overriding
   procedure Serve
     (T    : in out System_Transport;
      H    : in out Inspector_Transport.Request_Handler'Class;
      Stop : not null access function return Boolean)
   is
      pragma Unreferenced (T, H, Stop);
   begin
      null;
   end Serve;

   overriding
   procedure Close (T : in out System_Transport) is
   begin
      T.Listening := False;
   end Close;

   overriding
   function Ids
     (T : System_Transport; Work_Directory : String)
      return Synapse.Core.Text_Lists.Vector
   is
      pragma Unreferenced (T, Work_Directory);
      Nothing : Synapse.Core.Text_Lists.Vector;
   begin
      return Nothing;
   end Ids;

   overriding
   procedure Ask
     (T         : System_Transport;
      Endpoint  : String;
      Request   : String;
      Answered  : out Boolean;
      Answer    : out Unbounded_String)
   is
      pragma Unreferenced (T, Endpoint, Request);
   begin
      Answered := False;
      Answer :=
        To_Unbounded_String
          ("introspection is not available on this platform yet");
   end Ask;

end Synapse.Pipeline.System_Inspector;
