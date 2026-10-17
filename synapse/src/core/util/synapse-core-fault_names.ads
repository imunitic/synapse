with Ada.Exceptions;

--  The names faults are reported under, which are the names the contract of
--  the tool gave them: `EmptyDocument`, `PathTooLong`.
package Synapse.Core.Fault_Names with
  SPARK_Mode => Off
is

   --  `EMPTY_DOCUMENT` or `Empty_Document` as `EmptyDocument`.
   function Camel (Image : String) return String;

   --  The exception's own name, without the package it is declared in, as
   --  `Camel` writes it.
   function Of_Exception
     (E : Ada.Exceptions.Exception_Occurrence) return String;

end Synapse.Core.Fault_Names;
