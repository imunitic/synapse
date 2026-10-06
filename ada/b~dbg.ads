pragma Warnings (Off);
pragma Ada_95;
with System;
with System.Parameters;
with System.Secondary_Stack;
package ada_main is

   gnat_argc : Integer;
   gnat_argv : System.Address;
   gnat_envp : System.Address;

   pragma Import (C, gnat_argc);
   pragma Import (C, gnat_argv);
   pragma Import (C, gnat_envp);

   gnat_exit_status : Integer;
   pragma Import (C, gnat_exit_status);

   GNAT_Version : constant String :=
                    "GNAT Version: 16.1.0" & ASCII.NUL;
   pragma Export (C, GNAT_Version, "__gnat_version");

   GNAT_Version_Address : constant System.Address := GNAT_Version'Address;
   pragma Export (C, GNAT_Version_Address, "__gnat_version_address");

   Ada_Main_Program_Name : constant String := "_ada_dbg" & ASCII.NUL;
   pragma Export (C, Ada_Main_Program_Name, "__gnat_ada_main_program_name");

   procedure adainit;
   pragma Export (C, adainit, "adainit");

   procedure adafinal;
   pragma Export (C, adafinal, "adafinal");

   function main
     (argc : Integer;
      argv : System.Address;
      envp : System.Address)
      return Integer;
   pragma Export (C, main, "main");

   type Version_32 is mod 2 ** 32;
   u00001 : constant Version_32 := 16#ac104cbf#;
   pragma Export (C, u00001, "dbgB");
   u00002 : constant Version_32 := 16#b2cfab41#;
   pragma Export (C, u00002, "system__standard_libraryB");
   u00003 : constant Version_32 := 16#986fbd5a#;
   pragma Export (C, u00003, "system__standard_libraryS");
   u00004 : constant Version_32 := 16#76789da1#;
   pragma Export (C, u00004, "adaS");
   u00005 : constant Version_32 := 16#6ce3be0f#;
   pragma Export (C, u00005, "ada__exceptionsB");
   u00006 : constant Version_32 := 16#0fa7c4bb#;
   pragma Export (C, u00006, "ada__exceptionsS");
   u00007 : constant Version_32 := 16#85bf25f7#;
   pragma Export (C, u00007, "ada__exceptions__last_chance_handlerB");
   u00008 : constant Version_32 := 16#c1262c0b#;
   pragma Export (C, u00008, "ada__exceptions__last_chance_handlerS");
   u00009 : constant Version_32 := 16#8a611ac3#;
   pragma Export (C, u00009, "systemS");
   u00010 : constant Version_32 := 16#7fa0a598#;
   pragma Export (C, u00010, "system__soft_linksB");
   u00011 : constant Version_32 := 16#acdd2381#;
   pragma Export (C, u00011, "system__soft_linksS");
   u00012 : constant Version_32 := 16#33935a56#;
   pragma Export (C, u00012, "system__secondary_stackB");
   u00013 : constant Version_32 := 16#b0931c82#;
   pragma Export (C, u00013, "system__secondary_stackS");
   u00014 : constant Version_32 := 16#3007a9ef#;
   pragma Export (C, u00014, "system__parametersB");
   u00015 : constant Version_32 := 16#2bcfb19f#;
   pragma Export (C, u00015, "system__parametersS");
   u00016 : constant Version_32 := 16#46bfce2b#;
   pragma Export (C, u00016, "system__storage_elementsS");
   u00017 : constant Version_32 := 16#0286ce9f#;
   pragma Export (C, u00017, "system__soft_links__initializeB");
   u00018 : constant Version_32 := 16#ac2e8b53#;
   pragma Export (C, u00018, "system__soft_links__initializeS");
   u00019 : constant Version_32 := 16#8599b27b#;
   pragma Export (C, u00019, "system__stack_checkingB");
   u00020 : constant Version_32 := 16#4d3e0fd5#;
   pragma Export (C, u00020, "system__stack_checkingS");
   u00021 : constant Version_32 := 16#45e1965e#;
   pragma Export (C, u00021, "system__exception_tableB");
   u00022 : constant Version_32 := 16#074a6cda#;
   pragma Export (C, u00022, "system__exception_tableS");
   u00023 : constant Version_32 := 16#b8c4a5f1#;
   pragma Export (C, u00023, "system__exceptionsS");
   u00024 : constant Version_32 := 16#c367aa24#;
   pragma Export (C, u00024, "system__exceptions__machineB");
   u00025 : constant Version_32 := 16#8d1d496c#;
   pragma Export (C, u00025, "system__exceptions__machineS");
   u00026 : constant Version_32 := 16#2f7ce883#;
   pragma Export (C, u00026, "system__exceptions_debugB");
   u00027 : constant Version_32 := 16#ba6f4290#;
   pragma Export (C, u00027, "system__exceptions_debugS");
   u00028 : constant Version_32 := 16#1d4109f1#;
   pragma Export (C, u00028, "system__img_intS");
   u00029 : constant Version_32 := 16#5c7d9c20#;
   pragma Export (C, u00029, "system__tracebackB");
   u00030 : constant Version_32 := 16#0cfbee7e#;
   pragma Export (C, u00030, "system__tracebackS");
   u00031 : constant Version_32 := 16#5f6b6486#;
   pragma Export (C, u00031, "system__traceback_entriesB");
   u00032 : constant Version_32 := 16#427da54f#;
   pragma Export (C, u00032, "system__traceback_entriesS");
   u00033 : constant Version_32 := 16#727e0fa1#;
   pragma Export (C, u00033, "system__traceback__symbolicB");
   u00034 : constant Version_32 := 16#3e2e1203#;
   pragma Export (C, u00034, "system__traceback__symbolicS");
   u00035 : constant Version_32 := 16#701f9d88#;
   pragma Export (C, u00035, "ada__exceptions__tracebackB");
   u00036 : constant Version_32 := 16#47e3d2a3#;
   pragma Export (C, u00036, "ada__exceptions__tracebackS");
   u00037 : constant Version_32 := 16#f9910acc#;
   pragma Export (C, u00037, "system__address_imageB");
   u00038 : constant Version_32 := 16#2b8d87f9#;
   pragma Export (C, u00038, "system__address_imageS");
   u00039 : constant Version_32 := 16#bfdff066#;
   pragma Export (C, u00039, "system__img_address_32S");
   u00040 : constant Version_32 := 16#9111f9c1#;
   pragma Export (C, u00040, "interfacesS");
   u00041 : constant Version_32 := 16#92ff51e4#;
   pragma Export (C, u00041, "system__img_address_64S");
   u00042 : constant Version_32 := 16#fd158a37#;
   pragma Export (C, u00042, "system__wch_conB");
   u00043 : constant Version_32 := 16#536239a0#;
   pragma Export (C, u00043, "system__wch_conS");
   u00044 : constant Version_32 := 16#5c289972#;
   pragma Export (C, u00044, "system__wch_stwB");
   u00045 : constant Version_32 := 16#7e7315a1#;
   pragma Export (C, u00045, "system__wch_stwS");
   u00046 : constant Version_32 := 16#7cd63de5#;
   pragma Export (C, u00046, "system__wch_cnvB");
   u00047 : constant Version_32 := 16#55a2f3d0#;
   pragma Export (C, u00047, "system__wch_cnvS");
   u00048 : constant Version_32 := 16#e538de43#;
   pragma Export (C, u00048, "system__wch_jisB");
   u00049 : constant Version_32 := 16#e01591fa#;
   pragma Export (C, u00049, "system__wch_jisS");
   u00050 : constant Version_32 := 16#a201b8c5#;
   pragma Export (C, u00050, "ada__strings__text_buffersB");
   u00051 : constant Version_32 := 16#a7cfd09b#;
   pragma Export (C, u00051, "ada__strings__text_buffersS");
   u00052 : constant Version_32 := 16#e6d4fa36#;
   pragma Export (C, u00052, "ada__stringsS");
   u00053 : constant Version_32 := 16#8b7604c4#;
   pragma Export (C, u00053, "ada__strings__utf_encodingB");
   u00054 : constant Version_32 := 16#c9e86997#;
   pragma Export (C, u00054, "ada__strings__utf_encodingS");
   u00055 : constant Version_32 := 16#bb780f45#;
   pragma Export (C, u00055, "ada__strings__utf_encoding__stringsB");
   u00056 : constant Version_32 := 16#b85ff4b6#;
   pragma Export (C, u00056, "ada__strings__utf_encoding__stringsS");
   u00057 : constant Version_32 := 16#d1d1ed0b#;
   pragma Export (C, u00057, "ada__strings__utf_encoding__wide_stringsB");
   u00058 : constant Version_32 := 16#5678478f#;
   pragma Export (C, u00058, "ada__strings__utf_encoding__wide_stringsS");
   u00059 : constant Version_32 := 16#c2b98963#;
   pragma Export (C, u00059, "ada__strings__utf_encoding__wide_wide_stringsB");
   u00060 : constant Version_32 := 16#d7af3358#;
   pragma Export (C, u00060, "ada__strings__utf_encoding__wide_wide_stringsS");
   u00061 : constant Version_32 := 16#df45aed8#;
   pragma Export (C, u00061, "ada__tagsB");
   u00062 : constant Version_32 := 16#99822aba#;
   pragma Export (C, u00062, "ada__tagsS");
   u00063 : constant Version_32 := 16#3548d972#;
   pragma Export (C, u00063, "system__htableB");
   u00064 : constant Version_32 := 16#0bb84228#;
   pragma Export (C, u00064, "system__htableS");
   u00065 : constant Version_32 := 16#1f1abe38#;
   pragma Export (C, u00065, "system__string_hashB");
   u00066 : constant Version_32 := 16#acfdc257#;
   pragma Export (C, u00066, "system__string_hashS");
   u00067 : constant Version_32 := 16#704b659a#;
   pragma Export (C, u00067, "system__unsigned_typesS");
   u00068 : constant Version_32 := 16#159aaf05#;
   pragma Export (C, u00068, "system__val_lluS");
   u00069 : constant Version_32 := 16#0d1904b9#;
   pragma Export (C, u00069, "system__val_utilB");
   u00070 : constant Version_32 := 16#66caf8e0#;
   pragma Export (C, u00070, "system__val_utilS");
   u00071 : constant Version_32 := 16#8b956324#;
   pragma Export (C, u00071, "system__case_util_nssB");
   u00072 : constant Version_32 := 16#ef0e9ee9#;
   pragma Export (C, u00072, "system__case_util_nssS");
   u00073 : constant Version_32 := 16#c7620b41#;
   pragma Export (C, u00073, "ada__text_ioB");
   u00074 : constant Version_32 := 16#46a4a696#;
   pragma Export (C, u00074, "ada__text_ioS");
   u00075 : constant Version_32 := 16#6e6e3f5b#;
   pragma Export (C, u00075, "ada__streamsB");
   u00076 : constant Version_32 := 16#bd793559#;
   pragma Export (C, u00076, "ada__streamsS");
   u00077 : constant Version_32 := 16#367911c4#;
   pragma Export (C, u00077, "ada__io_exceptionsS");
   u00078 : constant Version_32 := 16#44f765f3#;
   pragma Export (C, u00078, "system__put_imagesB");
   u00079 : constant Version_32 := 16#9a7e9601#;
   pragma Export (C, u00079, "system__put_imagesS");
   u00080 : constant Version_32 := 16#22b9eb9f#;
   pragma Export (C, u00080, "ada__strings__text_buffers__utilsB");
   u00081 : constant Version_32 := 16#89062ac3#;
   pragma Export (C, u00081, "ada__strings__text_buffers__utilsS");
   u00082 : constant Version_32 := 16#1cacf006#;
   pragma Export (C, u00082, "interfaces__c_streamsB");
   u00083 : constant Version_32 := 16#ecfa876a#;
   pragma Export (C, u00083, "interfaces__c_streamsS");
   u00084 : constant Version_32 := 16#22b1fb99#;
   pragma Export (C, u00084, "system__crtlB");
   u00085 : constant Version_32 := 16#a9f4d4a9#;
   pragma Export (C, u00085, "system__crtlS");
   u00086 : constant Version_32 := 16#a94e7662#;
   pragma Export (C, u00086, "system__file_ioB");
   u00087 : constant Version_32 := 16#ec2e4f85#;
   pragma Export (C, u00087, "system__file_ioS");
   u00088 : constant Version_32 := 16#7598b591#;
   pragma Export (C, u00088, "ada__finalizationS");
   u00089 : constant Version_32 := 16#d00f339c#;
   pragma Export (C, u00089, "system__finalization_rootB");
   u00090 : constant Version_32 := 16#801d2417#;
   pragma Export (C, u00090, "system__finalization_rootS");
   u00091 : constant Version_32 := 16#14fb286b#;
   pragma Export (C, u00091, "system__case_utilB");
   u00092 : constant Version_32 := 16#5499fba9#;
   pragma Export (C, u00092, "system__case_utilS");
   u00093 : constant Version_32 := 16#8e328749#;
   pragma Export (C, u00093, "system__finalization_primitivesB");
   u00094 : constant Version_32 := 16#a30892a3#;
   pragma Export (C, u00094, "system__finalization_primitivesS");
   u00095 : constant Version_32 := 16#afd63177#;
   pragma Export (C, u00095, "system__os_locksS");
   u00096 : constant Version_32 := 16#b9ada65a#;
   pragma Export (C, u00096, "interfaces__cB");
   u00097 : constant Version_32 := 16#610373b9#;
   pragma Export (C, u00097, "interfaces__cS");
   u00098 : constant Version_32 := 16#1311b8a5#;
   pragma Export (C, u00098, "system__os_constantsS");
   u00099 : constant Version_32 := 16#861c956a#;
   pragma Export (C, u00099, "system__os_libB");
   u00100 : constant Version_32 := 16#b4b4641d#;
   pragma Export (C, u00100, "system__os_libS");
   u00101 : constant Version_32 := 16#94d23d25#;
   pragma Export (C, u00101, "system__atomic_operations__test_and_setB");
   u00102 : constant Version_32 := 16#57acee8e#;
   pragma Export (C, u00102, "system__atomic_operations__test_and_setS");
   u00103 : constant Version_32 := 16#4d0260e6#;
   pragma Export (C, u00103, "system__atomic_operationsS");
   u00104 : constant Version_32 := 16#553a519e#;
   pragma Export (C, u00104, "system__atomic_primitivesB");
   u00105 : constant Version_32 := 16#b0203cad#;
   pragma Export (C, u00105, "system__atomic_primitivesS");
   u00106 : constant Version_32 := 16#256dbbe5#;
   pragma Export (C, u00106, "system__stringsB");
   u00107 : constant Version_32 := 16#11e31adb#;
   pragma Export (C, u00107, "system__stringsS");
   u00108 : constant Version_32 := 16#e0daad44#;
   pragma Export (C, u00108, "system__file_control_blockS");
   u00109 : constant Version_32 := 16#ac6c5f06#;
   pragma Export (C, u00109, "synapseS");
   u00110 : constant Version_32 := 16#244ea70a#;
   pragma Export (C, u00110, "synapse__adaptersS");
   u00111 : constant Version_32 := 16#99d238a6#;
   pragma Export (C, u00111, "synapse__adapters__memory_byte_sourceB");
   u00112 : constant Version_32 := 16#699a73a3#;
   pragma Export (C, u00112, "synapse__adapters__memory_byte_sourceS");
   u00113 : constant Version_32 := 16#9969561e#;
   pragma Export (C, u00113, "system__storage_poolsB");
   u00114 : constant Version_32 := 16#0a664c89#;
   pragma Export (C, u00114, "system__storage_poolsS");
   u00115 : constant Version_32 := 16#36601f03#;
   pragma Export (C, u00115, "system__storage_pools__subpoolsB");
   u00116 : constant Version_32 := 16#219014ff#;
   pragma Export (C, u00116, "system__storage_pools__subpoolsS");
   u00117 : constant Version_32 := 16#20ec7aa3#;
   pragma Export (C, u00117, "system__ioB");
   u00118 : constant Version_32 := 16#1423ed8c#;
   pragma Export (C, u00118, "system__ioS");
   u00119 : constant Version_32 := 16#3676fd0b#;
   pragma Export (C, u00119, "system__storage_pools__subpools__finalizationB");
   u00120 : constant Version_32 := 16#4c972977#;
   pragma Export (C, u00120, "system__storage_pools__subpools__finalizationS");
   u00121 : constant Version_32 := 16#7e321c90#;
   pragma Export (C, u00121, "ada__strings__unboundedB");
   u00122 : constant Version_32 := 16#d6cc3e91#;
   pragma Export (C, u00122, "ada__strings__unboundedS");
   u00123 : constant Version_32 := 16#49d4c8e0#;
   pragma Export (C, u00123, "system__return_stackS");
   u00124 : constant Version_32 := 16#9a8aed35#;
   pragma Export (C, u00124, "ada__strings__mapsB");
   u00125 : constant Version_32 := 16#879d83f1#;
   pragma Export (C, u00125, "ada__strings__mapsS");
   u00126 : constant Version_32 := 16#d55f7fbe#;
   pragma Export (C, u00126, "system__bit_opsB");
   u00127 : constant Version_32 := 16#4792b6ff#;
   pragma Export (C, u00127, "system__bit_opsS");
   u00128 : constant Version_32 := 16#5b4659fa#;
   pragma Export (C, u00128, "ada__charactersS");
   u00129 : constant Version_32 := 16#cde9ea2d#;
   pragma Export (C, u00129, "ada__characters__latin_1S");
   u00130 : constant Version_32 := 16#28efec31#;
   pragma Export (C, u00130, "ada__strings__searchB");
   u00131 : constant Version_32 := 16#7f896bb3#;
   pragma Export (C, u00131, "ada__strings__searchS");
   u00132 : constant Version_32 := 16#52627794#;
   pragma Export (C, u00132, "system__atomic_countersB");
   u00133 : constant Version_32 := 16#5679f500#;
   pragma Export (C, u00133, "system__atomic_countersS");
   u00134 : constant Version_32 := 16#72726776#;
   pragma Export (C, u00134, "system__stream_attributesB");
   u00135 : constant Version_32 := 16#3bf21799#;
   pragma Export (C, u00135, "system__stream_attributesS");
   u00136 : constant Version_32 := 16#c027a94e#;
   pragma Export (C, u00136, "system__stream_attributes__xdrB");
   u00137 : constant Version_32 := 16#35ff530d#;
   pragma Export (C, u00137, "system__stream_attributes__xdrS");
   u00138 : constant Version_32 := 16#4953c5af#;
   pragma Export (C, u00138, "system__fat_fltS");
   u00139 : constant Version_32 := 16#6f61cca2#;
   pragma Export (C, u00139, "system__fat_lfltS");
   u00140 : constant Version_32 := 16#15b16248#;
   pragma Export (C, u00140, "system__fat_llfS");
   u00141 : constant Version_32 := 16#8cc2f281#;
   pragma Export (C, u00141, "synapse__portsS");
   u00142 : constant Version_32 := 16#679322fa#;
   pragma Export (C, u00142, "synapse__ports__byte_sourceS");
   u00143 : constant Version_32 := 16#579d64c6#;
   pragma Export (C, u00143, "system__taskingB");
   u00144 : constant Version_32 := 16#1ee3a9a0#;
   pragma Export (C, u00144, "system__taskingS");
   u00145 : constant Version_32 := 16#1472808a#;
   pragma Export (C, u00145, "system__task_primitivesS");
   u00146 : constant Version_32 := 16#2f25b9f8#;
   pragma Export (C, u00146, "system__os_interfaceB");
   u00147 : constant Version_32 := 16#27d51d6d#;
   pragma Export (C, u00147, "system__os_interfaceS");
   u00148 : constant Version_32 := 16#75266e31#;
   pragma Export (C, u00148, "system__c_timeB");
   u00149 : constant Version_32 := 16#f6136865#;
   pragma Export (C, u00149, "system__c_timeS");
   u00150 : constant Version_32 := 16#0343f0e1#;
   pragma Export (C, u00150, "system__task_primitives__operationsB");
   u00151 : constant Version_32 := 16#0a98e1c8#;
   pragma Export (C, u00151, "system__task_primitives__operationsS");
   u00152 : constant Version_32 := 16#4d23c29f#;
   pragma Export (C, u00152, "system__interrupt_managementB");
   u00153 : constant Version_32 := 16#96a36b4a#;
   pragma Export (C, u00153, "system__interrupt_managementS");
   u00154 : constant Version_32 := 16#414d8432#;
   pragma Export (C, u00154, "system__multiprocessorsB");
   u00155 : constant Version_32 := 16#b2cd85b0#;
   pragma Export (C, u00155, "system__multiprocessorsS");
   u00156 : constant Version_32 := 16#fb4ecb85#;
   pragma Export (C, u00156, "system__os_primitivesB");
   u00157 : constant Version_32 := 16#8d9c7f35#;
   pragma Export (C, u00157, "system__os_primitivesS");
   u00158 : constant Version_32 := 16#e0fce7f8#;
   pragma Export (C, u00158, "system__task_infoB");
   u00159 : constant Version_32 := 16#0a7ba7c2#;
   pragma Export (C, u00159, "system__task_infoS");
   u00160 : constant Version_32 := 16#3779e0d0#;
   pragma Export (C, u00160, "system__tasking__debugB");
   u00161 : constant Version_32 := 16#2f318f36#;
   pragma Export (C, u00161, "system__tasking__debugS");
   u00162 : constant Version_32 := 16#ca878138#;
   pragma Export (C, u00162, "system__concat_2B");
   u00163 : constant Version_32 := 16#3f9a6934#;
   pragma Export (C, u00163, "system__concat_2S");
   u00164 : constant Version_32 := 16#752a67ed#;
   pragma Export (C, u00164, "system__concat_3B");
   u00165 : constant Version_32 := 16#001b0361#;
   pragma Export (C, u00165, "system__concat_3S");
   u00166 : constant Version_32 := 16#b2148485#;
   pragma Export (C, u00166, "system__img_lliS");
   u00167 : constant Version_32 := 16#7c6f2528#;
   pragma Export (C, u00167, "system__stack_usageB");
   u00168 : constant Version_32 := 16#7bb67a7d#;
   pragma Export (C, u00168, "system__stack_usageS");
   u00169 : constant Version_32 := 16#8b6777ef#;
   pragma Export (C, u00169, "synapse__coreS");
   u00170 : constant Version_32 := 16#6f51e32d#;
   pragma Export (C, u00170, "synapse__core__refsB");
   u00171 : constant Version_32 := 16#149a827e#;
   pragma Export (C, u00171, "synapse__core__refsS");
   u00172 : constant Version_32 := 16#179d7d28#;
   pragma Export (C, u00172, "ada__containersS");
   u00173 : constant Version_32 := 16#c3b32edd#;
   pragma Export (C, u00173, "ada__containers__helpersB");
   u00174 : constant Version_32 := 16#f29f054d#;
   pragma Export (C, u00174, "ada__containers__helpersS");
   u00175 : constant Version_32 := 16#f4ca97ce#;
   pragma Export (C, u00175, "ada__containers__red_black_treesS");
   u00176 : constant Version_32 := 16#bcc987d2#;
   pragma Export (C, u00176, "system__concat_4B");
   u00177 : constant Version_32 := 16#b99945fd#;
   pragma Export (C, u00177, "system__concat_4S");
   u00178 : constant Version_32 := 16#be6f5d2e#;
   pragma Export (C, u00178, "system__strings__stream_opsB");
   u00179 : constant Version_32 := 16#9a9c0b11#;
   pragma Export (C, u00179, "system__strings__stream_opsS");
   u00180 : constant Version_32 := 16#02e43f40#;
   pragma Export (C, u00180, "system__pool_globalB");
   u00181 : constant Version_32 := 16#928ad74c#;
   pragma Export (C, u00181, "system__pool_globalS");
   u00182 : constant Version_32 := 16#a56a70fa#;
   pragma Export (C, u00182, "system__memoryB");
   u00183 : constant Version_32 := 16#92f586d9#;
   pragma Export (C, u00183, "system__memoryS");
   u00184 : constant Version_32 := 16#02cecc7b#;
   pragma Export (C, u00184, "system__concat_6B");
   u00185 : constant Version_32 := 16#0833ebcb#;
   pragma Export (C, u00185, "system__concat_6S");

   --  BEGIN ELABORATION ORDER
   --  ada%s
   --  ada.characters%s
   --  ada.characters.latin_1%s
   --  interfaces%s
   --  system%s
   --  system.atomic_operations%s
   --  system.case_util_nss%s
   --  system.case_util_nss%b
   --  system.io%s
   --  system.io%b
   --  system.parameters%s
   --  system.parameters%b
   --  system.crtl%s
   --  system.crtl%b
   --  interfaces.c_streams%s
   --  interfaces.c_streams%b
   --  system.storage_elements%s
   --  system.img_address_32%s
   --  system.img_address_64%s
   --  system.return_stack%s
   --  system.stack_checking%s
   --  system.stack_checking%b
   --  system.string_hash%s
   --  system.string_hash%b
   --  system.htable%s
   --  system.htable%b
   --  system.strings%s
   --  system.strings%b
   --  system.task_info%s
   --  system.task_info%b
   --  system.traceback_entries%s
   --  system.traceback_entries%b
   --  system.unsigned_types%s
   --  system.wch_con%s
   --  system.wch_con%b
   --  system.wch_jis%s
   --  system.wch_jis%b
   --  system.wch_cnv%s
   --  system.wch_cnv%b
   --  system.concat_2%s
   --  system.concat_2%b
   --  system.concat_3%s
   --  system.concat_3%b
   --  system.concat_4%s
   --  system.concat_4%b
   --  system.concat_6%s
   --  system.concat_6%b
   --  system.img_int%s
   --  system.stack_usage%s
   --  system.stack_usage%b
   --  system.img_lli%s
   --  system.traceback%s
   --  system.traceback%b
   --  system.secondary_stack%s
   --  system.standard_library%s
   --  ada.exceptions%s
   --  system.exceptions_debug%s
   --  system.exceptions_debug%b
   --  system.soft_links%s
   --  system.wch_stw%s
   --  system.wch_stw%b
   --  ada.exceptions.last_chance_handler%s
   --  ada.exceptions.last_chance_handler%b
   --  ada.exceptions.traceback%s
   --  ada.exceptions.traceback%b
   --  system.address_image%s
   --  system.address_image%b
   --  system.exception_table%s
   --  system.exception_table%b
   --  system.exceptions%s
   --  system.exceptions.machine%s
   --  system.exceptions.machine%b
   --  system.memory%s
   --  system.memory%b
   --  system.secondary_stack%b
   --  system.soft_links.initialize%s
   --  system.soft_links.initialize%b
   --  system.soft_links%b
   --  system.standard_library%b
   --  system.traceback.symbolic%s
   --  system.traceback.symbolic%b
   --  ada.exceptions%b
   --  ada.containers%s
   --  ada.io_exceptions%s
   --  ada.strings%s
   --  ada.strings.utf_encoding%s
   --  ada.strings.utf_encoding%b
   --  ada.strings.utf_encoding.strings%s
   --  ada.strings.utf_encoding.strings%b
   --  ada.strings.utf_encoding.wide_strings%s
   --  ada.strings.utf_encoding.wide_strings%b
   --  ada.strings.utf_encoding.wide_wide_strings%s
   --  ada.strings.utf_encoding.wide_wide_strings%b
   --  interfaces.c%s
   --  interfaces.c%b
   --  system.atomic_primitives%s
   --  system.atomic_primitives%b
   --  system.atomic_counters%s
   --  system.atomic_counters%b
   --  system.atomic_operations.test_and_set%s
   --  system.atomic_operations.test_and_set%b
   --  system.case_util%s
   --  system.case_util%b
   --  system.fat_flt%s
   --  system.fat_lflt%s
   --  system.fat_llf%s
   --  system.multiprocessors%s
   --  system.multiprocessors%b
   --  system.os_constants%s
   --  system.c_time%s
   --  system.c_time%b
   --  system.os_lib%s
   --  system.os_lib%b
   --  system.os_locks%s
   --  system.finalization_primitives%s
   --  system.finalization_primitives%b
   --  system.os_interface%s
   --  system.os_interface%b
   --  system.interrupt_management%s
   --  system.interrupt_management%b
   --  system.os_primitives%s
   --  system.os_primitives%b
   --  system.task_primitives%s
   --  system.tasking%s
   --  system.task_primitives.operations%s
   --  system.tasking.debug%s
   --  system.tasking.debug%b
   --  system.task_primitives.operations%b
   --  system.tasking%b
   --  system.val_util%s
   --  system.val_util%b
   --  system.val_llu%s
   --  ada.tags%s
   --  ada.tags%b
   --  ada.strings.text_buffers%s
   --  ada.strings.text_buffers%b
   --  ada.strings.text_buffers.utils%s
   --  ada.strings.text_buffers.utils%b
   --  system.put_images%s
   --  system.put_images%b
   --  ada.streams%s
   --  ada.streams%b
   --  system.file_control_block%s
   --  system.finalization_root%s
   --  system.finalization_root%b
   --  ada.finalization%s
   --  ada.containers.helpers%s
   --  ada.containers.helpers%b
   --  ada.containers.red_black_trees%s
   --  system.file_io%s
   --  system.file_io%b
   --  system.storage_pools%s
   --  system.storage_pools%b
   --  system.storage_pools.subpools%s
   --  system.storage_pools.subpools.finalization%s
   --  system.storage_pools.subpools.finalization%b
   --  system.storage_pools.subpools%b
   --  system.stream_attributes%s
   --  system.stream_attributes.xdr%s
   --  system.stream_attributes.xdr%b
   --  system.stream_attributes%b
   --  ada.text_io%s
   --  ada.text_io%b
   --  system.bit_ops%s
   --  system.bit_ops%b
   --  ada.strings.maps%s
   --  ada.strings.maps%b
   --  ada.strings.search%s
   --  ada.strings.search%b
   --  ada.strings.unbounded%s
   --  ada.strings.unbounded%b
   --  system.pool_global%s
   --  system.pool_global%b
   --  system.strings.stream_ops%s
   --  system.strings.stream_ops%b
   --  synapse%s
   --  synapse.adapters%s
   --  synapse.core%s
   --  synapse.ports%s
   --  synapse.ports.byte_source%s
   --  synapse.adapters.memory_byte_source%s
   --  synapse.adapters.memory_byte_source%b
   --  synapse.core.refs%s
   --  synapse.core.refs%b
   --  dbg%b
   --  END ELABORATION ORDER

end ada_main;
