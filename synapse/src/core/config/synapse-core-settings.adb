package body Synapse.Core.Settings is

   Vault_Dir_Name         : aliased constant String := "SYNAPSE_VAULT_DIR";
   Integrations_Name      : aliased constant String :=
     "SYNAPSE_VAULT_INTEGRATIONS";
   Grammars_Dir_Name      : aliased constant String := "SYNAPSE_GRAMMARS_DIR";
   Query_Path_Name        : aliased constant String :=
     "SYNAPSE_GRAMMARS_QUERY_PATH";
   Lock_Tries_Name        : aliased constant String :=
     "SYNAPSE_GRAMMAR_LOCK_TRIES";
   Push_Every_Name        : aliased constant String :=
     "SYNAPSE_VAULT_PUSH_EVERY";
   Author_Pool_Name       : aliased constant String := "SYNAPSE_AUTHOR_POOL";
   Staleness_Name         : aliased constant String :=
     "SYNAPSE_DOCSTRING_STALENESS_DETECTION";

   Vault_Dir_Text         : aliased constant String :=
     "The vault: the folder of notes that Synapse reads and writes.";
   Integrations_Text      : aliased constant String :=
     "The integrations layered on the vault's disk store, outermost first. " &
     "The only one is git, which keeps the vault in its own git history.";
   Grammars_Dir_Text      : aliased constant String :=
     "Where tree-sitter grammars are cloned and compiled, shared by every " &
     "project.";
   Query_Path_Text        : aliased constant String :=
     "A folder of hand-written tags queries that replace grammar discovery " &
     "for the extensions they name.";
   Lock_Tries_Text        : aliased constant String :=
     "How many 200 ms retries a grammar clone or compile waits for a lock " &
     "before giving up.";
   Push_Every_Text        : aliased constant String :=
     "With the git integration, how many local commits pile up before a " &
     "background push starts. 0 never pushes.";
   Author_Pool_Text       : aliased constant String :=
     "How many nodes /synapse-init writes at once. 0 writes them one at a " &
     "time in the same session.";
   Staleness_Text         : aliased constant String :=
     "Detect stale docstrings at edit time and in comments-check and " &
     "comments-sweep. Any non-empty value turns it on.";

   No_Default             : aliased constant String := "";
   Grammars_Default       : aliased constant String :=
     "~/.cache/synapse/grammars";
   Lock_Tries_Default     : aliased constant String := "300";
   Push_Every_Default     : aliased constant String := "5";
   Author_Pool_Default    : aliased constant String := "0";

   All_Settings : constant array (Index) of Setting :=
     [(Vault_Dir_Name'Access, Vault_Dir_Text'Access, No_Default'Access,
       Path_Kind, True, True),
      (Integrations_Name'Access, Integrations_Text'Access,
       No_Default'Access, List_Kind, False, True),
      (Grammars_Dir_Name'Access, Grammars_Dir_Text'Access,
       Grammars_Default'Access, Path_Kind, False, True),
      (Query_Path_Name'Access, Query_Path_Text'Access, No_Default'Access,
       Path_Kind, False, True),
      (Lock_Tries_Name'Access, Lock_Tries_Text'Access,
       Lock_Tries_Default'Access, Number_Kind, False, True),
      (Push_Every_Name'Access, Push_Every_Text'Access,
       Push_Every_Default'Access, Number_Kind, False, True),
      (Author_Pool_Name'Access, Author_Pool_Text'Access,
       Author_Pool_Default'Access, Number_Kind, False, False),
      (Staleness_Name'Access, Staleness_Text'Access, No_Default'Access,
       Toggle_Kind, False, True)];

   function Item (I : Index) return Setting is (All_Settings (I));

   function Find (Name : String) return Natural is
   begin
      for I in Index loop
         if All_Settings (I).Name.all = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

end Synapse.Core.Settings;
