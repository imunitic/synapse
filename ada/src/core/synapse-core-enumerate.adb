package body Synapse.Core.Enumerate is

   --  Binary by nature, grouped by what a file is: images and design files,
   --  audio and video, archives, packaged artefacts, compiled output, columnar
   --  and embedded data, serialized models and arrays, documents, fonts, keys
   --  and certificates. Each extension is delimited by spaces.
   Extensions : constant String :=
     " " & "png gif jpg jpeg bmp tif tiff webp avif ico svgz psd ai " &
     "sketch fig mp3 m4a wav flac ogg mp4 m4v mov avi mkv webm " &
     "zip gz tgz tar bz2 xz zst 7z rar jar war ear class aar apk " &
     "whl egg gem nupkg deb rpm dmg pkg msi o a obj lib pdb so " &
     "dylib dll exe rlib wasm node pyc pyo pyd beam parquet avro " &
     "orc db sqlite sqlite3 mdb pkl pickle npy npz h5 hdf5 onnx " &
     "pt pth ckpt safetensors gguf bin pdf xls xlsx doc docx ppt " &
     "pptx odt ods odp ttf otf woff woff2 eot keystore jks p12 " &
     "pem crt cer der ";

   function Extension_Of (Path : String) return String is
      Name_First : Natural := Path'First;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            Name_First := I + 1;
            exit;
         end if;
      end loop;
      for I in reverse Name_First .. Path'Last loop
         if Path (I) = '.' then
            --  A leading dot is a hidden file, not an extension.
            return (if I = Name_First then "" else Path (I + 1 .. Path'Last));
         end if;
      end loop;
      return "";
   end Extension_Of;

   function Is_Binary (Path : String) return Boolean is
      Extension : constant String := Extension_Of (Path);
   begin
      if Extension'Length = 0 or else (for some C of Extension => C = ' ') then
         return False;
      end if;
      for I in Extensions'First .. Extensions'Last - Extension'Length - 1 loop
         if Extensions (I) = ' '
           and then Extensions (I + 1 .. I + Extension'Length) = Extension
           and then Extensions (I + Extension'Length + 1) = ' '
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Binary;

end Synapse.Core.Enumerate;
