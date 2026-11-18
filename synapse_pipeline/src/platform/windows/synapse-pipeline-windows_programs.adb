with Ada.Characters.Conversions;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Strings.Wide_Unbounded;
with Ada.Wide_Characters.Handling;

with System;
with System.Address_To_Access_Conversions;
with System.Storage_Elements;

package body Synapse.Pipeline.Windows_Programs is

   use Ada.Strings.Unbounded;
   use type System.Address;
   use type Win32.C.wchar_t;
   use type Ada.Directories.File_Kind;

   function Is_File (Path : String) return Boolean is
   begin
      return Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File;
   exception
      when others =>
         return False;
   end Is_File;

   function Has_Separator (Text : String) return Boolean is
   begin
      for C of Text loop
         if C in '/' | '\' | ':' then
            return True;
         end if;
      end loop;
      return False;
   end Has_Separator;

   function Has_Extension (Name : String) return Boolean is
   begin
      for I in reverse Name'Range loop
         if Name (I) = '.' then
            return I > Name'First;
         elsif Name (I) in '/' | '\' then
            return False;
         end if;
      end loop;
      return False;
   end Has_Extension;

   --  The extensions a program may be run with, in the order they are tried.
   function Extensions return String is
     (if Ada.Environment_Variables.Exists ("PATHEXT")
      then Ada.Environment_Variables.Value ("PATHEXT")
      else ".COM;.EXE;.BAT;.CMD");

   --  Calls Visit with each part of Text between semicolons, until it says
   --  it is done.
   procedure Each_Part
     (Text  : String;
      Visit : not null access function (Part : String) return Boolean)
   is
      Start : Natural := Text'First;
   begin
      for I in Text'First .. Text'Last + 1 loop
         if I > Text'Last or else Text (I) = ';' then
            if I > Start and then Visit (Text (Start .. I - 1)) then
               return;
            end if;
            Start := I + 1;
         end if;
      end loop;
   end Each_Part;

   --  The file Base names: as it is when it has an extension, and with each
   --  of the extensions in turn when it has none. Empty when there is none.
   function With_Extension (Base : String) return String is
      Found : Unbounded_String;

      function Try (Extension : String) return Boolean is
      begin
         if Is_File (Base & Extension) then
            Found := To_Unbounded_String (Base & Extension);
            return True;
         end if;
         return False;
      end Try;
   begin
      if Has_Extension (Base) then
         return (if Is_File (Base) then Base else "");
      end if;
      Each_Part (Extensions, Try'Access);
      return To_String (Found);
   end With_Extension;

   --  The file a program name stands for: where it says, or else in the first
   --  directory on PATH that has it. Empty when there is none.
   function Locate (Program : String) return String is
      Found : Unbounded_String;

      function Look_In (Directory : String) return Boolean is
         Path : constant String :=
           With_Extension
             (Directory
              & (if Directory (Directory'Last) in '/' | '\' then "" else "\")
              & Program);
      begin
         if Path /= "" then
            Found := To_Unbounded_String (Path);
            return True;
         end if;
         return False;
      end Look_In;
   begin
      if Has_Separator (Program) then
         return With_Extension (Program);
      end if;
      if Ada.Environment_Variables.Exists ("PATH") then
         Each_Part (Ada.Environment_Variables.Value ("PATH"), Look_In'Access);
      end if;
      return To_String (Found);
   end Locate;

   function Is_Script (Path : String) return Boolean is
      Lower : constant Wide_String :=
        Ada.Wide_Characters.Handling.To_Lower
          (Ada.Characters.Conversions.To_Wide_String (Path));
   begin
      return Lower'Length >= 4
        and then Lower (Lower'Last - 3 .. Lower'Last) in ".cmd" | ".bat";
   end Is_Script;

   ---------------------------------------------------------------------------
   --  The command line
   ---------------------------------------------------------------------------

   --  Text as one argument of a command line, quoted the way the C library of
   --  Windows reads an argument back.
   function Quote (Text : String) return String is
      Needs   : Boolean := Text = "";
      Result  : Unbounded_String;
      Slashes : Natural := 0;
   begin
      for C of Text loop
         if C in ' ' | ASCII.HT | ASCII.LF | ASCII.VT | '"' then
            Needs := True;
         end if;
      end loop;
      if not Needs then
         return Text;
      end if;
      Append (Result, '"');
      for C of Text loop
         if C = '\' then
            Slashes := Slashes + 1;
         elsif C = '"' then
            Append (Result, [1 .. 2 * Slashes + 1 => '\']);
            Append (Result, '"');
            Slashes := 0;
         else
            Append (Result, [1 .. Slashes => '\']);
            Append (Result, C);
            Slashes := 0;
         end if;
      end loop;
      Append (Result, [1 .. 2 * Slashes => '\']);
      Append (Result, '"');
      return To_String (Result);
   end Quote;

   function Command_Line
     (Path : String; Arguments : Synapse.Core.Text_Lists.Vector) return String
   is
      Joined : Unbounded_String;
   begin
      for Arg of Arguments loop
         Append (Joined, " " & Quote (To_String (Arg)));
      end loop;
      if Is_Script (Path) then
         --  A script is run by the command interpreter, which takes off the
         --  first and the last quote of what follows /s.
         return
           "cmd.exe /d /s /c """ & Quote (Path) & To_String (Joined) & """";
      end if;
      return Quote (Path) & To_String (Joined);
   end Command_Line;

   ---------------------------------------------------------------------------
   --  The environment
   ---------------------------------------------------------------------------

   package Entries is new Ada.Containers.Indefinite_Ordered_Maps
     (Wide_String, Wide_String);

   package Chars is new System.Address_To_Access_Conversions
     (Win32.C.wchar_t);

   --  What tells an environment entry from the others: the name in lower
   --  case. The entries Windows keeps for each drive have a name that begins
   --  with `=`, which is not the one that ends it.
   function Name_Of (Item : Wide_String) return Wide_String is
   begin
      for I in Item'First + 1 .. Item'Last loop
         if Item (I) = '=' then
            return Ada.Wide_Characters.Handling.To_Lower
              (Item (Item'First .. I - 1));
         end if;
      end loop;
      return Ada.Wide_Characters.Handling.To_Lower (Item);
   end Name_Of;

   --  The variables of this program with Extra added, replacing any of the
   --  same name, as the block CreateProcess takes: each entry ended by a nul,
   --  in order of name, and the whole ended by another.
   function Environment_Block
     (Extra : Synapse.Core.Text_Lists.Vector) return Wide_String
   is
      Block  : constant System.Address := Win32.Get_Environment_Strings;
      Table  : Entries.Map;
      Index  : Natural := 0;
      Result : Ada.Strings.Wide_Unbounded.Unbounded_Wide_String;
      Freed  : Win32.BOOL;

      function Char_At (Position : Natural) return Win32.C.wchar_t is
        (Chars.To_Pointer
           (System.Storage_Elements."+"
              (Block,
               System.Storage_Elements.Storage_Offset
                 (Position * (Win32.C.wchar_t'Size / 8)))).all);
   begin
      if Block /= System.Null_Address then
         loop
            declare
               Start : constant Natural := Index;
            begin
               while Char_At (Index) /= Win32.C.wide_nul loop
                  Index := Index + 1;
               end loop;
               exit when Index = Start;
               declare
                  Item : Wide_String (1 .. Index - Start);
               begin
                  for K in Item'Range loop
                     Item (K) := Win32.C.To_Ada (Char_At (Start + K - 1));
                  end loop;
                  Table.Include (Name_Of (Item), Item);
               end;
               Index := Index + 1;
            end;
         end loop;
         Freed := Win32.Free_Environment_Strings (Block);
         pragma Unreferenced (Freed);
      end if;
      for Item of Extra loop
         declare
            Text : constant Wide_String :=
              Ada.Characters.Conversions.To_Wide_String (To_String (Item));
         begin
            Table.Include (Name_Of (Text), Text);
         end;
      end loop;
      for Item of Table loop
         Ada.Strings.Wide_Unbounded.Append (Result, Item);
         Ada.Strings.Wide_Unbounded.Append (Result, Wide_Character'Val (0));
      end loop;
      Ada.Strings.Wide_Unbounded.Append (Result, Wide_Character'Val (0));
      return Ada.Strings.Wide_Unbounded.To_Wide_String (Result);
   end Environment_Block;

   function Image (Item : Win32.DWORD) return String is
      Text : constant String := Win32.DWORD'Image (Item);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   procedure Close (Item : in out Win32.HANDLE) is
      Ignored : Win32.BOOL;
   begin
      if Item /= System.Null_Address and then Item /= Win32.Invalid_Handle
      then
         Ignored := Win32.Close_Handle (Item);
      end if;
      Item := System.Null_Address;
   end Close;

end Synapse.Pipeline.Windows_Programs;
