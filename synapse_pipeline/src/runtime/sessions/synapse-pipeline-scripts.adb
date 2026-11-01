package body Synapse.Pipeline.Scripts is

   procedure Add
     (Item   : in out Script; Step : String;
      Answer : Sessions.Session_Result; Pause : Duration := 0.0)
   is
   begin
      if not Item.Answers.Contains (Step) then
         Item.Answers.Insert (Step, Answer_Vectors.Empty_Vector);
      end if;
      Item.Answers (Step).Append
        (Entry_Type'(Answer => Answer, Pause => Pause));
   end Add;

   function Count (Item : Script; Step : String) return Natural is
     (if Item.Answers.Contains (Step)
      then Natural (Item.Answers.Element (Step).Length) else 0);

   function Answer
     (Item : Script; Step : String; Index : Positive)
      return Sessions.Session_Result is
     (Item.Answers.Element (Step) (Index).Answer);

   function Pause
     (Item : Script; Step : String; Index : Positive) return Duration is
     (Item.Answers.Element (Step) (Index).Pause);

end Synapse.Pipeline.Scripts;
