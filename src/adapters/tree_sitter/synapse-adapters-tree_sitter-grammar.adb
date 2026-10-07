with Ada.Unchecked_Conversion;
with System;

package body Synapse.Adapters.Tree_Sitter.Grammar with SPARK_Mode => Off is

   package Port renames Synapse.Ports.Library_Loader;

   use type System.Address;
   use type Thin.Language_Ptr;
   use type Port.Open_Status;

   --  The `TSLanguage *tree_sitter_<name>(void)` every grammar exports.
   type Language_Function is access function return Thin.Language_Ptr
   with Convention => C;

   function To_Function is new
     Ada.Unchecked_Conversion (System.Address, Language_Function);

   function Load_Language
     (Loader : in out Port.Loader'Class;
      Path   : String;
      Symbol : String) return Load_Result
   is
      Lib    : Port.Library;
      Status : Port.Open_Status;
   begin
      Loader.Open (Path, Lib, Status);
      case Status is
         when Port.Not_Found =>
            return Load_Results.Failure (Library_Not_Found);

         when Port.Not_A_Library =>
            return Load_Results.Failure (Not_A_Library);

         when Port.Opened =>
            null;
      end case;

      declare
         Address : constant System.Address := Loader.Symbol (Lib, Symbol);
      begin
         if Address = System.Null_Address then
            return Load_Results.Failure (Symbol_Not_Found);
         end if;

         declare
            Handle : constant Thin.Language_Ptr := To_Function (Address).all;
         begin
            if Handle = Thin.Null_Language then
               return Load_Results.Failure (Symbol_Not_Found);
            end if;

            declare
               Found : constant Language := (Handle => Handle);
               ABI   : constant Natural := ABI_Version (Found);
            begin
               if ABI < ABI_Min or else ABI > ABI_Max then
                  return Load_Results.Failure (Abi_Unsupported);
               end if;
               return Load_Results.Success (Found);
            end;
         end;
      end;
   end Load_Language;

end Synapse.Adapters.Tree_Sitter.Grammar;
