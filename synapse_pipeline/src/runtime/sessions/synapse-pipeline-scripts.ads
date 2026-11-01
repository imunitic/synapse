with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;

with Synapse.Pipeline.Sessions;

--  A script: for each step, the answers its sessions are given, in order. It
--  is the answers and nothing about how they are used up, which is for
--  whatever runs from it.

package Synapse.Pipeline.Scripts is

   type Script is private;

   Empty : constant Script;

   --  Adds Answer after the answers the step already has. A session given it
   --  takes Pause before it comes back.
   procedure Add
     (Item   : in out Script; Step : String;
      Answer : Sessions.Session_Result; Pause : Duration := 0.0);

   --  How many answers the step has.
   function Count (Item : Script; Step : String) return Natural;

   function Answer
     (Item : Script; Step : String; Index : Positive)
      return Sessions.Session_Result
   with Pre => Index <= Count (Item, Step);

   function Pause
     (Item : Script; Step : String; Index : Positive) return Duration
   with Pre => Index <= Count (Item, Step);

private

   type Entry_Type is record
      Answer : Sessions.Session_Result;
      Pause  : Duration := 0.0;
   end record;

   package Answer_Vectors is new Ada.Containers.Vectors
     (Positive, Entry_Type);

   package Answer_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Answer_Vectors.Vector, "<", Answer_Vectors."=");

   type Script is record
      Answers : Answer_Maps.Map;
   end record;

   Empty : constant Script := (Answers => Answer_Maps.Empty_Map);

end Synapse.Pipeline.Scripts;
