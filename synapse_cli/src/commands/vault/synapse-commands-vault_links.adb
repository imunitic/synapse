with Ada.Strings.Unbounded;

with Synapse.Commands.Vault_Support;
with Synapse.Commands.Vault_Usage;
with Synapse.Ports.Link_Graph;
with Synapse.Ports.Store;
with Synapse.Core.Decimal_Image;

package body Synapse.Commands.Vault_Links is

   use Ada.Strings.Unbounded;

   package Graph renames Synapse.Ports.Link_Graph;
   package Support renames Synapse.Commands.Vault_Support;

   Prog : constant String    := "synapse-vault";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   --  What a question about the graph writes, given the graph.
   type Question is
     access function
       (G : in out Graph.Link_Graph'Class; Node : String) return String;

   --  Runs Ask against the vault's link graph. Name is how a failure is
   --  reported, Takes_Path whether the subcommand names a note.
   function Ask
     (Env        : Environment; Args : Lists.Vector; Usage_Text, Name : String;
      Takes_Path : Boolean; Ask_Graph : Question) return Exit_Code
   is
      Path  : Unbounded_String;
      Vault : Unbounded_String;
      Found : Boolean;
      Stack : Support.Store_Resolve.Stack;
      Ok    : Boolean;
      Done  : Boolean;
      Code  : Exit_Code;
   begin
      if Takes_Path then
         Support.One_Path (Env, Args, Usage_Text, Path, Done, Code);
         if Done then
            return Code;
         end if;
      elsif not Args.Is_Empty then
         return Support.Help_Or_Usage (Env, To_String (Args (1)), Usage_Text);
      end if;
      Support.Find_Vault (Env, Prog, Vault, Found);
      if not Found then
         return 1;
      end if;
      Support.Open (Env, Prog, To_String (Vault), Stack, Ok);
      if not Ok then
         return 1;
      end if;
      Say
        (Env,
         Ask_Graph
           (Support.Store_Resolve.Link_Graph (Stack).all, To_String (Path)));
      return 0;
   exception
      when Synapse.Ports.Store.Store_Failure | Synapse.Ports.Store.Unsafe_Node
        | Synapse.Ports.Store.Node_Not_Found =>
         Complain (Env, Prog & ": " & Name & " failed" & LF);
         return 1;
   end Ask;

   function Backlinks_Text
     (G : in out Graph.Link_Graph'Class; Node : String) return String
   is
      Out_Text : Unbounded_String;
   begin
      for Hit of G.Backlinks (Node) loop
         Append
           (Out_Text,
            To_String (Hit.Node) & HT & Core.Decimal_Image.Image (Hit.Count) &
            LF);
      end loop;
      return To_String (Out_Text);
   end Backlinks_Text;

   function Links_Text
     (G : in out Graph.Link_Graph'Class; Node : String) return String
   is
      Out_Text : Unbounded_String;
   begin
      for Target of G.Links (Node) loop
         Append (Out_Text, To_String (Target) & LF);
      end loop;
      return To_String (Out_Text);
   end Links_Text;

   function Unresolved_Text
     (G : in out Graph.Link_Graph'Class; Node : String) return String
   is
      pragma Unreferenced (Node);
      Out_Text : Unbounded_String;
   begin
      for Row of G.Unresolved_Links loop
         for Source of Row.Sources loop
            Append
              (Out_Text,
               To_String (Source) & HT & To_String (Row.Target) & HT &
               Core.Decimal_Image.Image (Row.Count) & LF);
         end loop;
      end loop;
      return To_String (Out_Text);
   end Unresolved_Text;

   function Orphans_Text
     (G : in out Graph.Link_Graph'Class; Node : String) return String
   is
      pragma Unreferenced (Node);
      Out_Text : Unbounded_String;
   begin
      for Name of G.Orphans loop
         Append (Out_Text, To_String (Name) & LF);
      end loop;
      return To_String (Out_Text);
   end Orphans_Text;

   function Deadends_Text
     (G : in out Graph.Link_Graph'Class; Node : String) return String
   is
      pragma Unreferenced (Node);
      Out_Text : Unbounded_String;
   begin
      for Name of G.Dead_Ends loop
         Append (Out_Text, To_String (Name) & LF);
      end loop;
      return To_String (Out_Text);
   end Deadends_Text;

   function Ambiguous_Text
     (G : in out Graph.Link_Graph'Class; Node : String) return String
   is
      pragma Unreferenced (Node);
      Out_Text : Unbounded_String;
   begin
      for Row of G.Ambiguous_Links loop
         for Source of Row.Sources loop
            for Candidate of Row.Candidates loop
               Append
                 (Out_Text,
                  To_String (Source) & HT & To_String (Row.Target) & HT &
                  To_String (Candidate) & HT &
                  Core.Decimal_Image.Image (Row.Count) & LF);
            end loop;
         end loop;
      end loop;
      return To_String (Out_Text);
   end Ambiguous_Text;

   function Run_Backlinks
     (Env : Environment; Args : Lists.Vector) return Exit_Code is
     (Ask
        (Env, Args, Vault_Usage.Backlinks, "backlinks", True,
         Backlinks_Text'Access));

   function Run_Links
     (Env : Environment; Args : Lists.Vector) return Exit_Code is
     (Ask (Env, Args, Vault_Usage.Links, "links", True, Links_Text'Access));

   function Run_Unresolved
     (Env : Environment; Args : Lists.Vector) return Exit_Code is
     (Ask
        (Env, Args, Vault_Usage.Unresolved, "unresolved", False,
         Unresolved_Text'Access));

   function Run_Orphans
     (Env : Environment; Args : Lists.Vector) return Exit_Code is
     (Ask
        (Env, Args, Vault_Usage.Orphans, "orphans", False,
         Orphans_Text'Access));

   function Run_Deadends
     (Env : Environment; Args : Lists.Vector) return Exit_Code is
     (Ask
        (Env, Args, Vault_Usage.Deadends, "deadends", False,
         Deadends_Text'Access));

   function Run_Ambiguous
     (Env : Environment; Args : Lists.Vector) return Exit_Code is
     (Ask
        (Env, Args, Vault_Usage.Ambiguous, "ambiguous", False,
         Ambiguous_Text'Access));

end Synapse.Commands.Vault_Links;
