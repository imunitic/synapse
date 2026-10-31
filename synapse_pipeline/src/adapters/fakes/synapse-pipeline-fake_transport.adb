package body Synapse.Pipeline.Fake_Transport is

   use Ada.Strings.Unbounded;

   protected body Mailbox is

      procedure Put (Request : String) is
      begin
         Waiting.Append (To_Unbounded_String (Request));
      end Put;

      procedure Take (Request : out Unbounded_String; Found : out Boolean) is
      begin
         Found := not Waiting.Is_Empty;
         if Found then
            Request := Waiting.First_Element;
            Waiting.Delete_First;
         end if;
      end Take;

      procedure Answer (Text : String) is
      begin
         Given.Append (To_Unbounded_String (Text));
      end Answer;

      function Answers return Synapse.Core.Text_Lists.Vector is (Given);

      function Answered return Natural is (Natural (Given.Length));

   end Mailbox;

   overriding
   function Endpoint_For
     (T : Fake_Transport; Work_Directory, Id : String) return String
   is
      pragma Unreferenced (T);
   begin
      return Work_Directory & "/pipelines/" & Id & ".fake";
   end Endpoint_For;

   overriding
   procedure Listen
     (T         : in out Fake_Transport;
      Endpoint  : String;
      Listening : out Boolean;
      Reason    : out Unbounded_String)
   is
   begin
      T.Endpoint := To_Unbounded_String (Endpoint);
      Listening := not T.Refuse;
      Reason :=
        (if T.Refuse then To_Unbounded_String ("the fake refuses")
         else Null_Unbounded_String);
   end Listen;

   overriding
   procedure Serve
     (T    : in out Fake_Transport;
      H    : in out Inspector_Transport.Request_Handler'Class;
      Stop : not null access function return Boolean)
   is
      Request : Unbounded_String;
      Found   : Boolean;
   begin
      if T.Crash then
         raise Program_Error with "the fake was told to crash";
      end if;
      while not Stop.all loop
         T.Box.Take (Request, Found);
         if Found then
            T.Box.Answer (H.Respond (To_String (Request)));
         else
            delay 0.005;
         end if;
      end loop;
   end Serve;

   overriding
   procedure Close (T : in out Fake_Transport) is
   begin
      T.Closed := True;
   end Close;

   overriding
   function Ids
     (T : Fake_Transport; Work_Directory : String)
      return Synapse.Core.Text_Lists.Vector
   is
      pragma Unreferenced (Work_Directory);
      Sorted : Id_Sets.Set := T.Stale;
      Result : Synapse.Core.Text_Lists.Vector;
   begin
      for C in T.Runs.Iterate loop
         Sorted.Include (Run_Maps.Key (C));
      end loop;
      for Id of Sorted loop
         Result.Append (To_Unbounded_String (Id));
      end loop;
      return Result;
   end Ids;

   --  The id in an endpoint made by Endpoint_For.
   function Id_In (Endpoint : String) return String is
      First : Natural := Endpoint'First;
      Stop  : Natural := Endpoint'Last;
   begin
      for I in reverse Endpoint'Range loop
         if Endpoint (I) = '/' then
            First := I + 1;
            exit;
         end if;
      end loop;
      if Stop >= First + 4
        and then Endpoint (Stop - 4 .. Stop) = ".fake"
      then
         Stop := Stop - 5;
      end if;
      return Endpoint (First .. Stop);
   end Id_In;

   overriding
   procedure Ask
     (T         : Fake_Transport;
      Endpoint  : String;
      Request   : String;
      Answered  : out Boolean;
      Answer    : out Unbounded_String)
   is
      Id : constant String := Id_In (Endpoint);
   begin
      if T.Runs.Contains (Id) then
         Answered := True;
         Answer :=
           To_Unbounded_String
             (Inspection.Respond (T.Runs.Element (Id), Request));
      else
         Answered := False;
         Answer := To_Unbounded_String ("nothing is listening at " & Endpoint);
      end if;
   end Ask;

end Synapse.Pipeline.Fake_Transport;
