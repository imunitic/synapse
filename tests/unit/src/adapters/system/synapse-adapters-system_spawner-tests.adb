with Ada.Directories;
with Ada.Strings.Unbounded;
with GNAT.OS_Lib;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Scratch;
with AUnit.Assertions;

package body Synapse.Adapters.System_Spawner.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;

   LF : constant Character := Character'Val (10);

   --  Waits up to five seconds for a file to appear.
   function Appears (File : String) return Boolean is
   begin
      for Attempt in 1 .. 50 loop
         if Ada.Directories.Exists (File) then
            return True;
         end if;
         delay 0.1;
      end loop;
      return False;
   end Appears;

   --  Windows `echo` ends its line with CR LF.
   function Without_CR (Text : String) return String is
      Result : String (1 .. Text'Length);
      Last   : Natural := 0;
   begin
      for C of Text loop
         if C /= Character'Val (13) then
            Last := Last + 1;
            Result (Last) := C;
         end if;
      end loop;
      return Result (1 .. Last);
   end Without_CR;

   procedure The_Pusher_Is_Started_With_Its_Arguments_And_Not_Waited_For
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      On_Windows : constant Boolean :=
        GNAT.OS_Lib.Directory_Separator = '\';
      Script : constant String  :=
        Path (Dir, (if On_Windows then "pusher.cmd" else "pusher.sh"));
      Marker : constant String  := Path (Dir, "marker");
      S      : System_Spawner;
   begin
      Synapse.Adapters.File_Bytes.Write
        (Script,
         (if On_Windows then
            "@echo off" & LF & "ping -n 2 127.0.0.1 >nul" & LF &
            "(echo %1 %2 2)>""" & Marker & """" & LF
          else
            "#!/bin/sh" & LF & "sleep 1" & LF & "echo ""$1 $2 $#"" > """ &
            Marker & """" & LF));
      GNAT.OS_Lib.Set_Executable (Script);
      S.Program := To_Unbounded_String (Script);
      S.Spawn_Pusher ("/some/vault");
      Assert
        (not Ada.Directories.Exists (Marker),
         "it returned before the program was done");
      Assert (Appears (Marker), "the program ran");
      Assert
        (Without_CR (Synapse.Adapters.File_Bytes.Read (Marker, 1_000)) =
         "vault-git-pusher /some/vault 2" & LF,
         "its arguments");
   end The_Pusher_Is_Started_With_Its_Arguments_And_Not_Waited_For;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.System_Spawner");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Pusher_Is_Started_With_Its_Arguments_And_Not_Waited_For'Access,
         "The pusher is started with its arguments and not waited for");
   end Register_Tests;

end Synapse.Adapters.System_Spawner.Tests;
