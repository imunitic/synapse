with Ada.Exceptions;
with Ada.Text_IO;

with Synapse.Adapters.Git_Sync;

package body Synapse.Adapters.Git_Store is

   use Ada.Strings.Unbounded;

   function Create
     (Inner      : not null access Port.Store'Class;
      Runner     : not null access Ports.Process_Runner.Runner'Class;
      Vault      : String;
      Push_Every : Natural := 0;
      Spawner    : access Pusher_Spawner'Class := null) return Git_Store is
   begin
      return
        (Port.Store with
           Inner      => Inner,
           Runner     => Runner,
           Vault      => To_Unbounded_String (Vault),
           Push_Every => Push_Every,
           Spawner    => Spawner);
   end Create;

   overriding
   function Read (S : in out Git_Store; Node : String) return Port.Maybe_Text
   is (S.Inner.Read (Node));

   overriding
   function List (S : in out Git_Store) return Core.Text_Lists.Vector
   is (S.Inner.List);

   overriding
   function Search
     (S : in out Git_Store; Query : String) return Port.Hit_Vectors.Vector
   is (S.Inner.Search (Query));

   --  Asks for a background push when one is due: the number of commits
   --  ahead is a non-zero multiple of Push_Every.
   procedure Push_When_Due (S : in out Git_Store) is
   begin
      if S.Push_Every = 0 or else S.Spawner = null then
         return;
      end if;
      declare
         Ahead : constant Natural :=
           Git_Sync.Commits_Ahead (S.Runner.all, To_String (S.Vault));
      begin
         if Ahead /= 0 and then Ahead mod S.Push_Every = 0 then
            S.Spawner.Spawn_Pusher (To_String (S.Vault));
         end if;
      end;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "synapse: could not check whether a push is due ("
            & Ada.Exceptions.Exception_Name (E) & ")");
   end Push_When_Due;

   overriding
   function Write
     (S : in out Git_Store; Node, Content : String) return Port.Write_Result
   is
      Result    : constant Port.Write_Result := S.Inner.Write (Node, Content);
      Committed : Boolean;
   begin
      if not Result.Accepted then
         return Result;
      end if;
      Git_Sync.Commit_Under_Lock
        (S.Runner.all, To_String (S.Vault), Committed);
      if Committed then
         Push_When_Due (S);
      end if;
      return Result;
   end Write;

end Synapse.Adapters.Git_Store;
