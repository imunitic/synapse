--  A number as the digits a person writes: a minus sign for a negative one,
--  and no leading blank, which is what `'Image` puts in front of a number.
package Synapse.Core.Decimal_Image with
  SPARK_Mode => Off
is

   function Image (N : Long_Long_Integer) return String;

   function Image (N : Integer) return String;

end Synapse.Core.Decimal_Image;
