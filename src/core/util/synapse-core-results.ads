--  A value or the reason there is none, for the operations that can fail and
--  whose caller is expected to look: one generic in place of a record type per
--  operation. An exception is for what is not expected.
--
--  Value and Error say what they need to be called on, so asking a success
--  for its error fails the contract and not the program's meaning.

generic
   type Value_Type is private;
   type Error_Type is private;
package Synapse.Core.Results is

   type Result (Succeeded : Boolean := False) is private;

   function Success (Value : Value_Type) return Result with
     Post => Is_Success (Success'Result);

   function Failure (Error : Error_Type) return Result with
     Post => not Is_Success (Failure'Result);

   function Is_Success (R : Result) return Boolean;

   function Value (R : Result) return Value_Type with
     Pre => Is_Success (R);

   function Error (R : Result) return Error_Type with
     Pre => not Is_Success (R);

   --  The value of a success, Default for a failure.
   function Value_Or (R : Result; Default : Value_Type) return Value_Type;

private

   type Result (Succeeded : Boolean := False) is record
      case Succeeded is
         when True =>
            Item : Value_Type;

         when False =>
            Why : Error_Type;
      end case;
   end record;

end Synapse.Core.Results;
