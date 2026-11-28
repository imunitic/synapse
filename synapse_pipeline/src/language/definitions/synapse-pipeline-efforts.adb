with Ada.Characters.Handling;

package body Synapse.Pipeline.Efforts is

   use type Harnesses.Harness_Kind;

   type Name_Access is access constant String;
   type Name_List is array (Positive range <>) of Name_Access;

   Low        : aliased constant String := "low";
   Medium     : aliased constant String := "medium";
   High       : aliased constant String := "high";
   Xhigh      : aliased constant String := "xhigh";
   Max        : aliased constant String := "max";
   None       : aliased constant String := "none";
   Minimal    : aliased constant String := "minimal";
   Ultra      : aliased constant String := "ultra";
   Persistent : aliased constant String := "persistent";

   Claude_Efforts : constant Name_List :=
     (Low'Access, Medium'Access, High'Access, Xhigh'Access, Max'Access);

   --  The names Codex's `ReasoningEffort` enum knows.
   Codex_Efforts : constant Name_List :=
     (None'Access, Minimal'Access, Low'Access, Medium'Access, High'Access,
      Xhigh'Access, Max'Access, Ultra'Access, Persistent'Access);

   function Efforts_Of (Harness : Harnesses.Harness_Kind) return Name_List
   is (case Harness is
         when Harnesses.Claude   => Claude_Efforts,
         when Harnesses.Codex    => Codex_Efforts,
         when Harnesses.Opencode => (1 .. 0 => null));

   function Lower (Value : String) return String
     renames Ada.Characters.Handling.To_Lower;

   --  An OpenCode variant: `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`, so it
   --  cannot start with a dash or hold a `#`.
   function Is_Variant_Name (Value : String) return Boolean is
      --  ASCII only: Ada's Is_Alphanumeric also takes Latin-1 letters.
      function Is_Alphanumeric (C : Character) return Boolean is
        (C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9');
   begin
      if Value'Length = 0 or else Value'Length > 64
        or else not Is_Alphanumeric (Value (Value'First))
      then
         return False;
      end if;
      for C of Value loop
         if not (Is_Alphanumeric (C) or else C in '.' | '_' | '-') then
            return False;
         end if;
      end loop;
      return True;
   end Is_Variant_Name;

   function Is_Offered
     (Harness : Harnesses.Harness_Kind; Value : String) return Boolean is
   begin
      if Harness = Harnesses.Opencode then
         return Is_Variant_Name (Value);
      end if;
      for Name of Efforts_Of (Harness) loop
         if Lower (Value) = Name.all then
            return True;
         end if;
      end loop;
      return False;
   end Is_Offered;

   function Names (Harness : Harnesses.Harness_Kind) return String is
      List : constant Name_List := Efforts_Of (Harness);

      function From (Index : Positive) return String is
        (if Index > List'Last then ""
         elsif Index = List'Last then List (Index).all
         else List (Index).all & ", " & From (Index + 1));
   begin
      return From (List'First);
   end Names;

   function Normalized
     (Harness : Harnesses.Harness_Kind; Value : String) return String
   is (if Harness = Harnesses.Opencode then Value else Lower (Value));

end Synapse.Pipeline.Efforts;
