with Ada.Numerics.Discrete_Random;
with Ada.Strings.Unbounded;

with Synapse.Pipeline.Inspection;

package body Synapse.Pipeline.Inspectors is

   use Ada.Strings.Unbounded;

   type Word is mod 2**32;

   package Random_Words is new Ada.Numerics.Discrete_Random (Word);

   function New_Id return String is
      Generator : Random_Words.Generator;
      Value     : Word;
      Digits_Of : constant String := "0123456789abcdef";
      Id        : String := "exec-00000000";
   begin
      Random_Words.Reset (Generator);
      Value := Random_Words.Random (Generator);
      for I in reverse Id'Last - 7 .. Id'Last loop
         Id (I) := Digits_Of (Natural (Value mod 16) + 1);
         Value := Value / 16;
      end loop;
      return Id;
   end New_Id;

   --  The answerer: reads the context, never changes it, never raises.
   type Context_Handler
     (Context : not null access Contexts.Execution_Context)
   is limited new Inspector_Transport.Request_Handler with null record;

   overriding
   function Respond
     (H : in out Context_Handler; Request : String) return String
   is
   begin
      return Inspection.Respond (H.Context.Current, Request);
   exception
      when others =>
         return
           "{""ok"":false,""error"":""the request could not be answered""}";
   end Respond;

   procedure Serve_While
     (Transport : in out Inspector_Transport.Transport'Class;
      Endpoint  : String;
      Context   : aliased in out Contexts.Execution_Context;
      Action    : not null access procedure
        (Listening : Boolean; Reason : String))
   is
      Listening : Boolean;
      Reason    : Unbounded_String;
   begin
      Transport.Listen (Endpoint, Listening, Reason);
      if not Listening then
         Action (False, To_String (Reason));
         return;
      end if;

      begin
         declare
            protected Stopper is
               procedure Stop;
               function Stopped return Boolean;
            private
               Flag : Boolean := False;
            end Stopper;

            protected body Stopper is
               procedure Stop is
               begin
                  Flag := True;
               end Stop;

               function Stopped return Boolean is (Flag);
            end Stopper;

            function Should_Stop return Boolean is (Stopper.Stopped);

            Handler : Context_Handler (Context'Access);

            task Worker;

            task body Worker is
            begin
               Transport.Serve (Handler, Should_Stop'Access);
            exception
               when others =>
                  null;
            end Worker;
         begin
            begin
               Action (True, "");
            exception
               when others =>
                  Stopper.Stop;
                  raise;
            end;
            Stopper.Stop;
         end;
         Transport.Close;
      exception
         when others =>
            Transport.Close;
            raise;
      end;
   end Serve_While;

end Synapse.Pipeline.Inspectors;
