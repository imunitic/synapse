package body Synapse.Core.Results is

   function Success (Value : Value_Type) return Result is
     (Succeeded => True, Item => Value);

   function Failure (Error : Error_Type) return Result is
     (Succeeded => False, Why => Error);

   function Is_Success (R : Result) return Boolean is (R.Succeeded);

   function Value (R : Result) return Value_Type is (R.Item);

   function Error (R : Result) return Error_Type is (R.Why);

   function Value_Or (R : Result; Default : Value_Type) return Value_Type is
     (if R.Succeeded then R.Item else Default);

end Synapse.Core.Results;
