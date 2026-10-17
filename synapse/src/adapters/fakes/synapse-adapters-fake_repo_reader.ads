with Ada.Containers.Indefinite_Ordered_Maps;

with Synapse.Ports.Repo_Reader;

--  A repository held in memory, which counts how often it is read.

package Synapse.Adapters.Fake_Repo_Reader is

   type Reader is limited new Ports.Repo_Reader.Reader with private;

   procedure Put (R : in out Reader; Path, Content : String);

   --  How many reads were asked for, found or not.
   function Reads (R : Reader) return Natural;

   overriding function Read
     (R : in out Reader; Path : String) return Ports.Repo_Reader.Maybe_Content;

private

   package Files is new Ada.Containers.Indefinite_Ordered_Maps
     (String, String);

   type Reader is limited new Ports.Repo_Reader.Reader with record
      Content : Files.Map;
      Count   : Natural := 0;
   end record;

end Synapse.Adapters.Fake_Repo_Reader;
