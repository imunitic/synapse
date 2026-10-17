package body Synapse.Core.Grammar_Registry is

   package J renames Synapse.Core.JSON;

   use type J.Kind;

   function Parse (Text : String) return Registry is
      Parsed : constant J.Parse_Result := J.Parse (Text);
   begin
      if not Parsed.Ok then
         raise Malformed;
      end if;
      return (Root => Parsed.Item);
   end Parse;

   --  The entry of Extension when it is an object.
   procedure Entry_Of
     (R    :     Registry; Extension : String; Found : out Boolean;
      Item : out J.Value)
   is
   begin
      Found := False;
      Item  := J.Null_Value;
      if J.Kind_Of (R.Root) /= J.JSON_Object
        or else not J.Has_Member (R.Root, Extension)
      then
         return;
      end if;
      Item  := J.Member_Value (R.Root, Extension);
      Found := J.Kind_Of (Item) = J.JSON_Object;
   end Entry_Of;

   --  A string member, whatever its length.
   function String_Member
     (Object : J.Value; Key : String; Value : out Unbounded_String)
      return Boolean
   is
   begin
      Value := Null_Unbounded_String;
      if not J.Has_Member (Object, Key) then
         return False;
      end if;
      declare
         Item : constant J.Value := J.Member_Value (Object, Key);
      begin
         if J.Kind_Of (Item) /= J.JSON_String then
            return False;
         end if;
         Value := To_Unbounded_String (J.As_String (Item));
         return True;
      end;
   end String_Member;

   function Source_Of_Entry (Object : J.Value) return Query_Source is
      Name : Unbounded_String;
   begin
      if String_Member (Object, "queries", Name) then
         if Name = "locals" then
            return Locals;
         elsif Name = "generated" then
            return Generated;
         end if;
      end if;
      return Tags;
   end Source_Of_Entry;

   package Sorting is new Text_Lists.Vectors.Generic_Sorting
     ("<" => Ada.Strings.Unbounded."<");

   function Usable_Extensions (R : Registry) return Text_Lists.Vector is
      Result : Text_Lists.Vector;
   begin
      if J.Kind_Of (R.Root) /= J.JSON_Object then
         return Result;
      end if;
      for I in 1 .. J.Length (R.Root) loop
         declare
            Key : constant String := J.Member_Key (R.Root, I);
         begin
            if Lookup (R, Key).Kind = Ready
              and then not Result.Contains (To_Unbounded_String (Key))
            then
               Result.Append (To_Unbounded_String (Key));
            end if;
         end;
      end loop;
      Sorting.Sort (Result);
      return Result;
   end Usable_Extensions;

   function Lookup (R : Registry; Extension : String) return Readiness is
      Item  : J.Value;
      Found : Boolean;
      Repo  : Unbounded_String;
      Scope : Unbounded_String;
   begin
      if J.Kind_Of (R.Root) /= J.JSON_Object
        or else not J.Has_Member (R.Root, Extension)
      then
         return (Kind => No_Entry);
      end if;
      Entry_Of (R, Extension, Found, Item);
      if not Found then
         return (Kind => Unusable);
      end if;
      if J.Has_Member (Item, "unsupported")
        and then J.Kind_Of (J.Member_Value (Item, "unsupported")) =
          J.JSON_Boolean
        and then J.As_Boolean (J.Member_Value (Item, "unsupported"))
      then
         return (Kind => Unusable);
      end if;
      if not String_Member (Item, "repo", Repo)
        or else not String_Member (Item, "scope", Scope)
        or else Length (Repo) = 0 or else Length (Scope) = 0
      then
         return (Kind => Unusable);
      end if;
      return (Kind => Ready, Scope => Scope, Source => Source_Of_Entry (Item));
   end Lookup;

   function Source_Of (R : Registry; Extension : String) return Query_Source is
      Item  : J.Value;
      Found : Boolean;
   begin
      Entry_Of (R, Extension, Found, Item);
      return (if Found then Source_Of_Entry (Item) else Tags);
   end Source_Of;

   function Field_Of
     (R : Registry; Extension, Key : String; Allow_Empty : Boolean)
      return Maybe_Text
   is
      Item  : J.Value;
      Found : Boolean;
      Value : Unbounded_String;
   begin
      Entry_Of (R, Extension, Found, Item);
      if not Found or else not String_Member (Item, Key, Value) then
         return (Found => False);
      end if;
      if Length (Value) = 0 and then not Allow_Empty then
         return (Found => False);
      end if;
      return (Found => True, Value => Value);
   end Field_Of;

   function Repo_For (R : Registry; Extension : String) return Maybe_Text is
     (Field_Of (R, Extension, "repo", Allow_Empty => True));

   function Path_For (R : Registry; Extension : String) return Maybe_Text is
     (Field_Of (R, Extension, "path", Allow_Empty => False));

   function Symbol_For (R : Registry; Extension : String) return Maybe_Text is
     (Field_Of (R, Extension, "symbol", Allow_Empty => False));

   function Extension_Of (Path : String) return String is
      Base_First : Positive := Path'First;
      Dot        : Natural  := 0;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            Base_First := I + 1;
            exit;
         end if;
      end loop;
      for I in reverse Base_First .. Path'Last loop
         if Path (I) = '.' then
            Dot := I;
            exit;
         end if;
      end loop;
      if Dot = 0 or else Dot = Path'Last then
         return "";
      end if;
      declare
         Result : String := Path (Dot + 1 .. Path'Last);
      begin
         for C of Result loop
            if C in 'A' .. 'Z' then
               C := Character'Val (Character'Pos (C) + 32);
            end if;
         end loop;
         return Result;
      end;
   end Extension_Of;

   Prefix : constant String := "tree-sitter-";

   function Symbol_For (Repo_Name : String) return String is
      Starts : constant Boolean :=
        Repo_Name'Length >= Prefix'Length
        and then
          Repo_Name (Repo_Name'First .. Repo_Name'First + Prefix'Length - 1) =
          Prefix;
      Stem   : String           :=
        (if Starts then
           Repo_Name (Repo_Name'First + Prefix'Length .. Repo_Name'Last)
         else Repo_Name);
   begin
      for C of Stem loop
         if C = '-' then
            C := '_';
         end if;
      end loop;
      return "tree_sitter_" & Stem;
   end Symbol_For;

   function Repo_Name_Of (Url : String) return String is
      Last : Natural := Url'Last;
   begin
      while Last >= Url'First and then Url (Last) = '/' loop
         Last := Last - 1;
      end loop;
      declare
         Trimmed : constant String := Url (Url'First .. Last);
         First   : Positive        := Trimmed'First;
      begin
         for I in reverse Trimmed'Range loop
            if Trimmed (I) = '/' then
               First := I + 1;
               exit;
            end if;
         end loop;
         declare
            Base : constant String := Trimmed (First .. Trimmed'Last);
         begin
            if Base'Length >= 4
              and then Base (Base'Last - 3 .. Base'Last) = ".git"
            then
               return Base (Base'First .. Base'Last - 4);
            end if;
            return Base;
         end;
      end;
   end Repo_Name_Of;

end Synapse.Core.Grammar_Registry;
