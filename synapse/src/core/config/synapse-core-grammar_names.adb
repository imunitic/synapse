package body Synapse.Core.Grammar_Names with SPARK_Mode is

   function Symbol_For (Repo_Name : String) return String is
      Skip        : constant Natural :=
        (if Has_Repo_Prefix (Repo_Name) then Repo_Prefix'Length else 0);
      Stem_Length : constant Natural := Repo_Name'Length - Skip;
      Result      : String (1 .. Symbol_Prefix'Length + Stem_Length) :=
        [others => '_'];
   begin
      Result (1 .. Symbol_Prefix'Length) := Symbol_Prefix;
      for K in 1 .. Stem_Length loop
         pragma Loop_Invariant
           (Result (1 .. Symbol_Prefix'Length) = Symbol_Prefix);
         declare
            C : constant Character :=
              Repo_Name (Repo_Name'First + Skip + (K - 1));
         begin
            Result (Symbol_Prefix'Length + K) := (if C = '-' then '_' else C);
         end;
      end loop;
      return Result;
   end Symbol_For;

end Synapse.Core.Grammar_Names;
