with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with Synapse.Adapters.Conf_Files;

package body Synapse.Adapters.Store_Resolve is

   use Ada.Strings.Unbounded;

   Setting : constant String := "SYNAPSE_VAULT_INTEGRATIONS";

   --  What each integration is spelled as in the setting.
   function Is_Known (Name : String) return Boolean is (Name = "git");

   function Trimmed (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last and then S (First) in ' ' | Character'Val (9) loop
         First := First + 1;
      end loop;
      while Last >= First and then S (Last) in ' ' | Character'Val (9) loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trimmed;

   function Refuse (Text : String) return Parse_Result is
     (Parse_Results.Failure (To_Unbounded_String (Text)));

   function Parse_Integrations (Value : String) return Parse_Result is
      Names : Core.Text_Lists.Vector;
      Start : Natural := Value'First;
   begin
      if Value'Length = 0 then
         return Parse_Results.Success (Names);
      end if;
      for I in Value'First .. Value'Last + 1 loop
         if I > Value'Last or else Value (I) = ',' then
            declare
               Name : constant String := Trimmed (Value (Start .. I - 1));
            begin
               if Name = "disk" then
                  return
                    Refuse
                      (Setting & " names 'disk' -- the disk store is always " &
                       "the implicit innermost element, never named " &
                       "explicitly");
               elsif not Is_Known (Name) then
                  return
                    Refuse
                      ("unknown integration '" & Name & "' in " & Setting &
                       " -- want 'git'");
               elsif Names.Contains (To_Unbounded_String (Name)) then
                  return
                    Refuse
                      ("'" & Name & "' named more than once in " & Setting);
               elsif Natural (Names.Length) >= Max_Integrations then
                  return Refuse ("too many entries in " & Setting);
               end if;
               Names.Append (To_Unbounded_String (Name));
            end;
            Start := I + 1;
         end if;
      end loop;
      return Parse_Results.Success (Names);
   end Parse_Integrations;

   function Configured (Vars : Ports.Variables.Variables'Class) return String
   is
      Found : constant Conf_Files.Maybe_Path :=
        Conf_Files.Resolve (Vars, Setting);
   begin
      return (if Found.Found then To_String (Found.Value) else "");
   end Configured;

   function Has_Integration
     (Vars : Ports.Variables.Variables'Class; Name : String) return Boolean
   is
      Parsed : constant Parse_Result := Parse_Integrations (Configured (Vars));
   begin
      return
        Parse_Results.Is_Success (Parsed)
        and then Parse_Results.Value (Parsed).Contains
          (To_Unbounded_String (Name));
   end Has_Integration;

   procedure Free is new Ada.Unchecked_Deallocation
     (Disk_Store.Disk_Store, Disk_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Schema_Validation_Store.Validation_Store, Validation_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Git_Store.Git_Store, Git_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (System_Process.System_Runner, Runner_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (System_Clock.System_Clock, Clock_Access);

   procedure Free is new Ada.Unchecked_Deallocation
     (Disk_Link_Graph.Disk_Link_Graph, Graph_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Disk_Renamer.Disk_Renamer, Disk_Renamer_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Disk_Deleter.Disk_Deleter, Disk_Deleter_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Git_Capabilities.Git_Renamer, Git_Renamer_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Git_Capabilities.Git_Deleter, Git_Deleter_Access);

   overriding procedure Finalize (S : in out Stack) is
   begin
      Free (S.Git_Mover);
      Free (S.Git_Remover);
      Free (S.Mover);
      Free (S.Remover);
      Free (S.Graph);
      Free (S.Git);
      Free (S.Validation);
      Free (S.Disk);
      Free (S.Runner);
      Free (S.Clock);
   end Finalize;

   procedure Resolve
     (S : in out Stack; Vars : not null access Ports.Variables.Variables'Class;
      Vault   :        String; Namespace : String; Prog : String;
      Spawner :    access Git_Store.Pusher_Spawner'Class; Valid : out Boolean)
   is
      Parsed : constant Parse_Result :=
        Parse_Integrations (Configured (Vars.all));
   begin
      Finalize (S);
      Valid := Parse_Results.Is_Success (Parsed);
      if not Parse_Results.Is_Success (Parsed) then
         if Prog'Length > 0 then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               Prog & ": " & To_String (Parse_Results.Error (Parsed)));
         end if;
         return;
      end if;

      S.Runner := new System_Process.System_Runner;
      S.Clock  := new System_Clock.System_Clock;
      S.Disk   :=
        new Disk_Store.Disk_Store'(Disk_Store.Create (Vault, Namespace));
      S.Disk.Set_Stopwords (Conf_Files.Load_Stopwords (Vars.all));
      S.Graph   :=
        new Disk_Link_Graph.Disk_Link_Graph'(Disk_Link_Graph.Create (Vault));
      S.Mover   := new Disk_Renamer.Disk_Renamer'(Disk_Renamer.Create (Vault));
      S.Remover := new Disk_Deleter.Disk_Deleter'(Disk_Deleter.Create (Vault));

      --  Validation is a correctness boundary, not a selectable
      --  integration: it always wraps the disk store and every integration
      --  wraps it.
      S.Validation :=
        new Schema_Validation_Store.Validation_Store'
          (Schema_Validation_Store.Create (S.Disk, Vars, S.Clock));

      if Parse_Results.Value (Parsed).Contains (To_Unbounded_String ("git"))
      then
         S.Git         :=
           new Git_Store.Git_Store'
             (Git_Store.Create
                (Inner => S.Validation, Runner => S.Runner, Vault => Vault,
                 Push_Every => Conf_Files.Push_Every (Vars.all),
                 Spawner    => Spawner));
         S.Git_Mover   :=
           new Git_Capabilities.Git_Renamer'
             (Git_Capabilities.Create (S.Mover, S.Runner, Vault));
         S.Git_Remover :=
           new Git_Capabilities.Git_Deleter'
             (Git_Capabilities.Create (S.Remover, S.Runner, Vault));
      end if;
   end Resolve;

   function Store (S : in out Stack) return not null access Port.Store'Class is
     (if S.Git /= null then Port.Store'Class (S.Git.all)'Access
      else Port.Store'Class (S.Validation.all)'Access);

   function Link_Graph
     (S : in out Stack)
      return not null access Ports.Link_Graph.Link_Graph'Class is
     (Ports.Link_Graph.Link_Graph'Class (S.Graph.all)'Access);

   function Renamer
     (S : in out Stack) return not null access Ports.Renamer.Renamer'Class is
     (if S.Git_Mover /= null then
        Ports.Renamer.Renamer'Class (S.Git_Mover.all)'Access
      else Ports.Renamer.Renamer'Class (S.Mover.all)'Access);

   function Deleter
     (S : in out Stack) return not null access Ports.Deleter.Deleter'Class is
     (if S.Git_Remover /= null then
        Ports.Deleter.Deleter'Class (S.Git_Remover.all)'Access
      else Ports.Deleter.Deleter'Class (S.Remover.all)'Access);

   function Search_Filtered
     (S      : in out Stack; Query : String;
      Filter :        Ports.Search_Filtered.Path_Filter)
      return Port.Hit_Vectors.Vector is
     (S.Disk.Search_Filtered (Query, Filter));

end Synapse.Adapters.Store_Resolve;
