with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Clients;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Registry_Store;

package body Synapse.Pipeline.Commands.Changes is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Changes_Help);

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   --  One patch of the record, by what its name says.
   type Patch_Name is record
      Name    : Unbounded_String;
      Step    : Unbounded_String;
      Visit   : Natural := 0;
      Attempt : Natural := 0;
   end record;

   function Comes_First (Left, Right : Patch_Name) return Boolean is
     (Left.Visit < Right.Visit
      or else
        (Left.Visit = Right.Visit and then Left.Attempt < Right.Attempt));

   package Name_Vectors is new Ada.Containers.Vectors (Positive, Patch_Name);
   package Sorting is new Name_Vectors.Generic_Sorting (Comes_First);

   function Is_Number (Text : String) return Boolean is
     (Text'Length in 1 .. 9 and then (for all C of Text => C in '0' .. '9'));

   --  Reads a name of the form `Visit-Step-Attempt.patch`; a step's name has
   --  no '-' in it.
   function Read_Name (Name : String; Item : out Patch_Name) return Boolean is
      Suffix : constant String := ".patch";
      First  : Natural := 0;
      Last   : Natural := 0;
   begin
      Item := (others => <>);
      if Name'Length <= Suffix'Length
        or else Name (Name'Last - Suffix'Length + 1 .. Name'Last) /= Suffix
      then
         return False;
      end if;
      declare
         Stem : constant String :=
           Name (Name'First .. Name'Last - Suffix'Length);
      begin
         for I in Stem'Range loop
            if Stem (I) = '-' then
               if First = 0 then
                  First := I;
               end if;
               Last := I;
            end if;
         end loop;
         if First = 0 or else Last = First
           or else not Is_Number (Stem (Stem'First .. First - 1))
           or else not Is_Number (Stem (Last + 1 .. Stem'Last))
         then
            return False;
         end if;
         Item :=
           (Name    => To_Unbounded_String (Name),
            Step    => To_Unbounded_String (Stem (First + 1 .. Last - 1)),
            Visit   => Natural'Value (Stem (Stem'First .. First - 1)),
            Attempt => Natural'Value (Stem (Last + 1 .. Stem'Last)));
         return True;
      end;
   end Read_Name;

   function Image (Item : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Item), Ada.Strings.Left));

   --  The folder the run's steps worked in, which its summary says when it
   --  was told.
   function Directory_Of (Summary : Registry_Store.Maybe_Content)
      return JSON.Value
   is
   begin
      if not Summary.Found then
         return JSON.Null_Value;
      end if;
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (To_String (Summary.Value));
      begin
         if Parsed.Ok
           and then JSON.Kind_Of (Parsed.Item) = JSON.JSON_Object
           and then JSON.Has_Member (Parsed.Item, "directory")
           and then JSON.Kind_Of (JSON.Member_Value (Parsed.Item, "directory"))
                    = JSON.JSON_String
         then
            return JSON.Member_Value (Parsed.Item, "directory");
         end if;
         return JSON.Null_Value;
      end;
   end Directory_Of;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Id         : Unbounded_String;
      Step       : Unbounded_String;
      Format     : Unbounded_String := To_Unbounded_String ("text");
      Has_Step   : Boolean := False;
      Has_Format : Boolean := False;
      I          : Positive := Args.First_Index;
   begin
      while I <= Args.Last_Index loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Arg = "--step" or else Arg = "--format" then
               if I = Args.Last_Index
                 or else (Arg = "--step" and then Has_Step)
                 or else (Arg = "--format" and then Has_Format)
               then
                  return Usage_Error (Env, Usage);
               end if;
               I := I + 1;
               if Arg = "--step" then
                  Has_Step := True;
                  Step := Args (I);
               else
                  Has_Format := True;
                  Format := Args (I);
               end if;
            elsif Arg'Length >= 2
              and then Arg (Arg'First .. Arg'First + 1) = "--"
            then
               return Usage_Error (Env, Usage);
            elsif Length (Id) > 0 then
               return Usage_Error (Env, Usage);
            else
               Id := Args (I);
            end if;
         end;
         I := I + 1;
      end loop;
      if Length (Id) = 0
        or else (To_String (Format) /= "text"
                 and then To_String (Format) /= "json")
      then
         return Usage_Error (Env, Usage);
      end if;

      declare
         Work   : Unbounded_String;
         Found  : Boolean;
         Known  : Boolean := False;
         Items  : Name_Vectors.Vector;
         Parsed : Patch_Name;
      begin
         Clients.Work_Directory (Env, Work, Found);
         if not Found then
            return 1;
         end if;
         Env.Registry.Open (To_String (Work));
         for Held of Env.Registry.Ids loop
            if Held = Id then
               Known := True;
            end if;
         end loop;
         if not Known then
            Complain
              (Env,
               "error: there is no record of execution '" & To_String (Id)
               & "'" & LF);
            return 1;
         end if;
         for Name of Env.Registry.Patch_Names (To_String (Id)) loop
            if Read_Name (To_String (Name), Parsed)
              and then (not Has_Step or else Parsed.Step = Step)
            then
               Items.Append (Parsed);
            end if;
         end loop;
         Sorting.Sort (Items);

         if To_String (Format) = "json" then
            declare
               Steps : JSON.Value_Array (1 .. Natural (Items.Length));
               Place : Natural := 0;
            begin
               for Item of Items loop
                  Place := Place + 1;
                  Steps (Place) :=
                    JSON.Make_Object
                      ([Member
                          ("step", JSON.Make_String (To_String (Item.Step))),
                        Member
                          ("visit",
                           JSON.Make_Integer (Long_Long_Integer (Item.Visit))),
                        Member
                          ("attempt",
                           JSON.Make_Integer
                             (Long_Long_Integer (Item.Attempt))),
                        Member
                          ("patch",
                           JSON.Make_String
                             (To_String
                                (Env.Registry.Read_Patch
                                   (To_String (Id), To_String (Item.Name))
                                 .Value)))]);
               end loop;
               Say
                 (Env,
                  JSON.To_String
                    (JSON.Make_Object
                       ([Member
                           ("format",
                            JSON.Make_String
                              ("synapse-pipeline-changes/v1")),
                         Member
                           ("execution_id", JSON.Make_String (To_String (Id))),
                         Member
                           ("directory",
                            Directory_Of
                              (Env.Registry.Read_Summary (To_String (Id)))),
                         Member ("steps", JSON.Make_Array (Steps))]))
                  & LF);
            end;
            return 0;
         end if;

         if Items.Is_Empty then
            Say
              (Env,
               "no changes were recorded"
               & (if Has_Step then " for step " & To_String (Step) else "")
               & LF);
            return 0;
         end if;
         for Item of Items loop
            declare
               Held : constant Registry_Store.Maybe_Content :=
                 Env.Registry.Read_Patch
                   (To_String (Id), To_String (Item.Name));
               Text : constant String :=
                 (if Held.Found then To_String (Held.Value) else "");
            begin
               Say
                 (Env,
                  "== step " & To_String (Item.Step) & " (visit "
                  & Image (Item.Visit) & ", attempt " & Image (Item.Attempt)
                  & ")" & LF & Text
                  & (if Text'Length > 0 and then Text (Text'Last) /= LF
                     then String'(1 => LF) else ""));
            end;
         end loop;
         return 0;
      end;
   end Run;

end Synapse.Pipeline.Commands.Changes;
