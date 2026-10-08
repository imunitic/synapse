package body Synapse.Core.Timestamps is

   function Built_At (Rfc3339 : String) return String is
     (Rfc3339 (Rfc3339'First .. Rfc3339'First + 9) & ' ' &
      Rfc3339 (Rfc3339'First + 11 .. Rfc3339'First + 15));

end Synapse.Core.Timestamps;
