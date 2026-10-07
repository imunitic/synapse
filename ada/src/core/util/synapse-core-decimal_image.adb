package body Synapse.Core.Decimal_Image is

   function Image (N : Long_Long_Integer) return String is
      Text : constant String := N'Image;
   begin
      return
        (if Text (Text'First) = ' ' then Text (Text'First + 1 .. Text'Last)
         else Text);
   end Image;

   function Image (N : Integer) return String is
     (Image (Long_Long_Integer (N)));

end Synapse.Core.Decimal_Image;
