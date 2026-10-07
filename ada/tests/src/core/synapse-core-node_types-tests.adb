with AUnit.Assertions;

with Synapse.Core.Kind_Synonyms;

package body Synapse.Core.Node_Types.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   No_Rules : Kind_Synonyms.Rule_List;

   function Describe (Guesses : Guess_Vectors.Vector) return String is
      Text : Unbounded_String;
   begin
      for G of Guesses loop
         Append
           (Text,
            To_String (G.Type_Name) & ":" & To_String (G.Kind) & ":" &
            (if G.Has_Name_Field then "Y" else "N") & ";");
      end loop;
      return To_String (Text);
   end Describe;

   function Classified (Json : String) return String is
     (Describe (Classify (Json, No_Rules, "test-scope")));

   procedure An_Anonymous_Type_Is_Never_A_Declaration
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classified ("[{""type"":""class_declaration"",""named"":false}]") =
         "",
         "anonymous");
      Assert
        (Classified ("[{""type"":""class_declaration""}]") = "",
         "no named field at all");
      Assert
        (Classified ("[{""type"":""class_declaration"",""named"":1}]") = "",
         "named is not a boolean");
   end An_Anonymous_Type_Is_Never_A_Declaration;

   procedure A_Plain_Node_With_No_Declaration_Name_Is_Skipped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classified
           ("[{""type"":""identifier"",""named"":true}," &
            "{""type"":""block"",""named"":true}]") =
         "",
         "plain nodes");
      Assert
        (Classified ("[{""type"":"""",""named"":true}]") = "",
         "an empty type name");
      Assert
        (Classified ("[5,""x"",null]") = "", "entries that are no objects");
   end A_Plain_Node_With_No_Declaration_Name_Is_Skipped;

   procedure A_Suffix_With_No_Prefix_Word_Gets_The_Generic_Kind
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classified
           ("[{""type"":""function_declaration"",""named"":true," &
            """fields"":{""name"":{}}}]") =
         "function_declaration:function:Y;",
         "function");
   end A_Suffix_With_No_Prefix_Word_Gets_The_Generic_Kind;

   procedure A_Prefix_Word_Becomes_The_Kind (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Classified
           ("[{""type"":""struct_item"",""named"":true," &
            """fields"":{""name"":{}}}]") =
         "struct_item:struct:Y;",
         "struct");
   end A_Prefix_Word_Becomes_The_Kind;

   procedure Prefix_Words_Map_To_The_Kinds_A_Grammars_Locals_Use
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classified
           ("[{""type"":""package_declaration"",""named"":true}," &
            "{""type"":""import_declaration"",""named"":true}," &
            "{""type"":""const_declaration"",""named"":true}," &
            "{""type"":""variable_declaration"",""named"":true}," &
            "{""type"":""ParamDecl"",""named"":true}," &
            "{""type"":""VarDecl"",""named"":true}," &
            "{""type"":""TestDecl"",""named"":true}," &
            "{""type"":""ContainerDecl"",""named"":true}," &
            "{""type"":""ErrorSetDecl"",""named"":true}]") =
         "package_declaration:namespace:N;import_declaration:namespace:N;" &
         "const_declaration:constant:N;variable_declaration:var:N;" &
         "ParamDecl:parameter:N;VarDecl:var:N;TestDecl:test:N;" &
         "ContainerDecl:type:N;ErrorSetDecl:type:N;",
         "the kinds");
   end Prefix_Words_Map_To_The_Kinds_A_Grammars_Locals_Use;

   procedure A_Prefix_Word_Must_Land_On_A_Boundary
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classified ("[{""type"":""StructureDecl"",""named"":true}]") =
         "StructureDecl:function:N;",
         "a lowercase continuation is not the word");
      Assert
        (Classified ("[{""type"":""classy_thing"",""named"":true}]") = "",
         "not the word, and no suffix");
      Assert
        (Classified ("[{""type"":""constant_declaration"",""named"":true}]") =
         "constant_declaration:function:N;",
         "const is not constant");
   end A_Prefix_Word_Must_Land_On_A_Boundary;

   procedure Declaration_Suffixes_Match_In_Any_Case
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classified
           ("[{""type"":""VarDecl"",""named"":true}," &
            "{""type"":""TestDef"",""named"":true}," &
            "{""type"":""FnProto"",""named"":true}]") =
         "VarDecl:var:N;TestDef:test:N;",
         "the PascalCase spelling");
   end Declaration_Suffixes_Match_In_Any_Case;

   procedure A_Bare_Prefix_Word_Is_Not_A_Declaration
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classified
           ("[{""type"":""struct"",""named"":true}," &
            "{""type"":""struct_type"",""named"":true}," &
            "{""type"":""struct_declaration"",""named"":true," &
            """fields"":{""name"":{}}}]") =
         "struct_declaration:struct:Y;",
         "a type expression is not a declaration");
   end A_Bare_Prefix_Word_Is_Not_A_Declaration;

   procedure A_Type_With_No_Fields_Has_No_Name_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Classified ("[{""type"":""variable_declaration"",""named"":true}]") =
         "variable_declaration:var:N;",
         "no fields");
      Assert
        (Classified
           ("[{""type"":""variable_declaration"",""named"":true," &
            """fields"":[]}]") =
         "variable_declaration:var:N;",
         "fields that are not an object");
      Assert
        (Classified
           ("[{""type"":""variable_declaration"",""named"":true," &
            """fields"":{""value"":{}}}]") =
         "variable_declaration:var:N;",
         "fields without a name");
   end A_Type_With_No_Fields_Has_No_Name_Field;

   procedure A_Non_Array_Classifies_To_Nothing_And_Bad_Json_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      Assert (Classified ("{}") = "", "an object");
      begin
         Assert (Classified ("[") = "", "unreachable");
      exception
         when Malformed =>
            Raised := True;
      end;
      Assert (Raised, "text that is not JSON");
   end A_Non_Array_Classifies_To_Nothing_And_Bad_Json_Is_Refused;

   procedure A_Rule_Names_A_Type_The_Heuristic_Misses
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Rules : constant Kind_Synonyms.Rule_List :=
        Kind_Synonyms.Parse
          ("[{""match"":""unit_body"",""scope"":""source.wdg""," &
           """kind"":""function""}]");
      Json  : constant String                  :=
        "[{""type"":""unit_body"",""named"":true," &
        """fields"":{""name"":{}}}]";
   begin
      Assert
        (Describe (Classify (Json, Rules, "source.other")) = "",
         "another scope: still nothing");
      Assert
        (Describe (Classify (Json, Rules, "source.wdg")) =
         "unit_body:function:Y;",
         "its own scope: classified");
   end A_Rule_Names_A_Type_The_Heuristic_Misses;

   procedure A_Rule_Relabels_A_Type_The_Heuristic_Caught
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Rules : constant Kind_Synonyms.Rule_List :=
        Kind_Synonyms.Parse
          ("[{""match"":""struct_item"",""kind"":""record""}]");
   begin
      Assert
        (Describe
           (Classify
              ("[{""type"":""struct_item""," & """named"":true}]", Rules,
               "s")) =
         "struct_item:record:N;",
         "the rule's kind wins");
   end A_Rule_Relabels_A_Type_The_Heuristic_Caught;

   procedure The_Query_Has_One_Pattern_Per_Named_Guess
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Guesses : Guess_Vectors.Vector;
   begin
      Assert (Build_Query (Guesses) = "", "none");
      Guesses.Append
        (Guess'
           (To_Unbounded_String ("function_declaration"),
            To_Unbounded_String ("function"), True));
      Guesses.Append
        (Guess'
           (To_Unbounded_String ("variable_declaration"),
            To_Unbounded_String ("function"), False));
      Guesses.Append
        (Guess'
           (To_Unbounded_String ("struct_item"),
            To_Unbounded_String ("struct"), True));
      Assert
        (Build_Query (Guesses) =
         "(function_declaration name: (_) @name) @definition.function" &
         Character'Val (10) &
         "(struct_item name: (_) @name) @definition.struct" &
         Character'Val (10),
         "the ones with a name field");
      Guesses.Clear;
      Guesses.Append
        (Guess'
           (To_Unbounded_String ("variable_declaration"),
            To_Unbounded_String ("function"), False));
      Assert (Build_Query (Guesses) = "", "walk-only guesses add nothing");
   end The_Query_Has_One_Pattern_Per_Named_Guess;

   --  Two hundred and fifty-three type names of every case and shape, and what
   --  an independent implementation of the same rules (regular expressions,
   --  written separately from this package) made of them.
   Generated_Json : constant String :=
     "[{""type"":""PackageDefinition"",""named"":false,""field" &
     "s"":{""name"":{}}},{""type"":""specifier"",""named"":tru" &
     "e},{""type"":""NAMESPACE_WIDGET_DEF"",""named"":true},{""" &
     "type"":""PackageWidgetItemDeclaration"",""named"":true,""" &
     "fields"":{""name"":{}}},{""type"":""Def"",""named"":true" &
     "},{""type"":""name_node"",""named"":true},{""type"":""st" &
     "ruct_ref_decl"",""named"":true,""fields"":{""name"":{}}}" &
     ",{""type"":""BodySpecifier"",""named"":true},{""type"":""" &
     "item"",""named"":true},{""type"":""node_name_item"",""na" &
     "med"":true,""fields"":{""name"":{}}},{""type"":""TestTyp" &
     "eName_item"",""named"":true},{""type"":""ImportValueSpec" &
     "ifier"",""named"":false},{""type"":""ModuleThingName"",""" &
     "named"":true,""fields"":{""name"":{}}},{""type"":""packa" &
     "ge_gadget_definition"",""named"":true},{""type"":""Impor" &
     "tDeclaration"",""named"":true},{""type"":""type_list__sp" &
     "ecifier"",""named"":true,""fields"":{""name"":{}}},{""ty" &
     "pe"":""_item"",""named"":true},{""type"":""body_list_def" &
     """,""named"":true},{""type"":""StructGadgetGadgetDeclara" &
     "tion"",""named"":true,""fields"":{""name"":{}}},{""type""" &
     ":""SpecDeclaration"",""named"":true},{""type"":""gadget_" &
     "ref_def"",""named"":true},{""type"":""ExprSpecifier"",""" &
     "named"":true,""fields"":{""name"":{}}},{""type"":""class" &
     "_node_node"",""named"":false},{""type"":""widget_ref_def" &
     """,""named"":true},{""type"":""param_value_ref_item"",""" &
     "named"":true,""fields"":{""name"":{}}},{""type"":""list_" &
     "value_decl"",""named"":true},{""type"":""list_type__item" &
     """,""named"":true},{""type"":""interface_decl"",""named""" &
     ":true,""fields"":{""name"":{}}},{""type"":""variable_nod" &
     "e_decl"",""named"":true},{""type"":""node_node__specifie" &
     "r"",""named"":true},{""type"":""enum_gadget__item"",""na" &
     "med"":true,""fields"":{""name"":{}}},{""type"":""BODY_BO" &
     "DY__ITEM"",""named"":true},{""type"":""name__binding"",""" &
     "named"":true},{""type"":""ConstTypeNameBinding"",""named" &
     """:false,""fields"":{""name"":{}}},{""type"":""ModuleVal" &
     "ueThingDecl"",""named"":true},{""type"":""interface_expr" &
     """,""named"":true},{""type"":""plain"",""named"":true,""" &
     "fields"":{""name"":{}}},{""type"":""EnumItem"",""named""" &
     ":true},{""type"":""widget_def"",""named"":true},{""type""" &
     ":""ModuleValueDeclaration"",""named"":true,""fields"":{""" &
     "name"":{}}},{""type"":""VariableDeclaration"",""named"":" &
     "true},{""type"":""const_type_expr_declaration"",""named""" &
     ":true},{""type"":""Definition"",""named"":true,""fields""" &
     ":{""name"":{}}},{""type"":""def"",""named"":true},{""typ" &
     "e"":""import_item_ref"",""named"":false},{""type"":""LIS" &
     "T_DEFINITION"",""named"":true,""fields"":{""name"":{}}}," &
     "{""type"":""GADGET"",""named"":true},{""type"":""TYPE_SP" &
     "EC"",""named"":true},{""type"":""TestSpecSpecifier"",""n" &
     "amed"":true,""fields"":{""name"":{}}},{""type"":""Struct" &
     "Type"",""named"":true},{""type"":""gadget_ref__specifier" &
     """,""named"":true},{""type"":""ImportItemNode"",""named""" &
     ":true,""fields"":{""name"":{}}},{""type"":""parameter""," &
     """named"":true},{""type"":""module_name_expr_item"",""na" &
     "med"":true},{""type"":""StructGadgetRefDeclaration"",""n" &
     "amed"":true,""fields"":{""name"":{}}},{""type"":""parame" &
     "ter_list_definition"",""named"":false},{""type"":""ref__" &
     "specifier"",""named"":true},{""type"":""error_item_def""" &
     ",""named"":true,""fields"":{""name"":{}}},{""type"":""in" &
     "terface_ref__specifier"",""named"":true},{""type"":""Tes" &
     "tNodeGadgetDeclaration"",""named"":true},{""type"":""Nam" &
     "eBinding"",""named"":true,""fields"":{""name"":{}}},{""t" &
     "ype"":""STRUCT_REF"",""named"":true},{""type"":""ClassTh" &
     "ingRefItem"",""named"":true},{""type"":""list"",""named""" &
     ":true,""fields"":{""name"":{}}},{""type"":""namespace_sp" &
     "ec_declaration"",""named"":true},{""type"":""trait_ref_s" &
     "pec"",""named"":true},{""type"":""IMPORT_THING_BODY_DECL" &
     "ARATION"",""named"":false,""fields"":{""name"":{}}},{""t" &
     "ype"":""ref_binding"",""named"":true},{""type"":""test_n" &
     "ode_def"",""named"":true},{""type"":""_binding"",""named" &
     """:true,""fields"":{""name"":{}}},{""type"":""test_item_" &
     "expr"",""named"":true},{""type"":""gadget_node_decl"",""" &
     "named"":true},{""type"":""_specifier"",""named"":true,""" &
     "fields"":{""name"":{}}},{""type"":""BINDING"",""named"":" &
     "true},{""type"":""TraitNameRef_item"",""named"":true},{""" &
     "type"":""ClassListDefinition"",""named"":true,""fields""" &
     ":{""name"":{}}},{""type"":""test_list_declaration"",""na" &
     "med"":true},{""type"":""container_widget_def"",""named""" &
     ":false},{""type"":""parameter_ref_definition"",""named""" &
     ":true,""fields"":{""name"":{}}},{""type"":""container_sp" &
     "ec_name"",""named"":true},{""type"":""thing_type__specif" &
     "ier"",""named"":true},{""type"":""gadget_widget__binding" &
     """,""named"":true,""fields"":{""name"":{}}},{""type"":""" &
     "body_node_declaration"",""named"":true},{""type"":""modu" &
     "le_spec_list_specifier"",""named"":true},{""type"":""con" &
     "st_ref_ref_definition"",""named"":true,""fields"":{""nam" &
     "e"":{}}},{""type"":""EnumBodyWidgetDeclaration"",""named" &
     """:true},{""type"":""node_definition"",""named"":true},{" &
     """type"":""parameter_widget_declaration"",""named"":true" &
     ",""fields"":{""name"":{}}},{""type"":""ParameterList"",""" &
     "named"":false},{""type"":""NodeDefinition"",""named"":tr" &
     "ue},{""type"":""ContainerItemDecl"",""named"":true,""fie" &
     "lds"":{""name"":{}}},{""type"":""import_definition"",""n" &
     "amed"":true},{""type"":""Trait"",""named"":true},{""type" &
     """:""widget_decl"",""named"":true,""fields"":{""name"":{" &
     "}}},{""type"":""VariableDecl"",""named"":true},{""type""" &
     ":""enum__binding"",""named"":true},{""type"":""Container" &
     "BodyWidget_specifier"",""named"":true,""fields"":{""name" &
     """:{}}},{""type"":""thing"",""named"":true},{""type"":""" &
     "ParameterRefValueDef"",""named"":true},{""type"":""decla" &
     "ration"",""named"":false,""fields"":{""name"":{}}},{""ty" &
     "pe"":""interface_gadget__binding"",""named"":true},{""ty" &
     "pe"":""TypeList"",""named"":true},{""type"":""NameTypeSp" &
     "ecifier"",""named"":true,""fields"":{""name"":{}}},{""ty" &
     "pe"":""import_gadget_declaration"",""named"":true},{""ty" &
     "pe"":""value_spec__item"",""named"":true},{""type"":""it" &
     "em_ref_item"",""named"":true,""fields"":{""name"":{}}},{" &
     """type"":""struct_node_spec"",""named"":true},{""type"":" &
     """namespace_decl"",""named"":true},{""type"":""VAR_REF""" &
     ",""named"":true,""fields"":{""name"":{}}},{""type"":""Bo" &
     "dyRef"",""named"":true},{""type"":""CONST_ITEM_ITEM"",""" &
     "named"":false},{""type"":""VarSpecItemDecl"",""named"":t" &
     "rue,""fields"":{""name"":{}}},{""type"":""container_valu" &
     "e_item"",""named"":true},{""type"":""class_thing_gadget""" &
     ",""named"":true},{""type"":""Type"",""named"":true,""fie" &
     "lds"":{""name"":{}}},{""type"":""namespace_expr__binding" &
     """,""named"":true},{""type"":""expr"",""named"":true},{""" &
     "type"":""list_value"",""named"":true,""fields"":{""name""" &
     ":{}}},{""type"":""StructSpecSpecDecl"",""named"":true},{" &
     """type"":""CONST_TYPE__BINDING"",""named"":true},{""type" &
     """:""var_list__binding"",""named"":true,""fields"":{""na" &
     "me"":{}}},{""type"":""module_gadget_spec_def"",""named""" &
     ":false},{""type"":""definition"",""named"":true},{""type" &
     """:""trait_expr_widget_def"",""named"":true,""fields"":{" &
     """name"":{}}},{""type"":""interface_node_item"",""named""" &
     ":true},{""type"":""interface_body_binding"",""named"":tr" &
     "ue},{""type"":""ThingItemSpecifier"",""named"":true,""fi" &
     "elds"":{""name"":{}}},{""type"":""list__item"",""named""" &
     ":true},{""type"":""VariableValueGadgetDeclaration"",""na" &
     "med"":true},{""type"":""TestThingBinding"",""named"":tru" &
     "e,""fields"":{""name"":{}}},{""type"":""struct_declarati" &
     "on"",""named"":true},{""type"":""InterfaceDefinition"",""" &
     "named"":true},{""type"":""enum_decl"",""named"":false,""" &
     "fields"":{""name"":{}}},{""type"":""ParameterBodyExprDec" &
     "laration"",""named"":true},{""type"":""interface_type""," &
     """named"":true},{""type"":""widget_gadget_specifier"",""" &
     "named"":true,""fields"":{""name"":{}}},{""type"":""value" &
     "_declaration"",""named"":true},{""type"":""ParamBodyDef""" &
     ",""named"":true},{""type"":""struct_decl"",""named"":tru" &
     "e,""fields"":{""name"":{}}},{""type"":""CONTAINER_NAME__" &
     "ITEM"",""named"":true},{""type"":""container_body_specif" &
     "ier"",""named"":true},{""type"":""interface_specifier""," &
     """named"":true,""fields"":{""name"":{}}},{""type"":""Var" &
     "Expr"",""named"":true},{""type"":""value_body__specifier" &
     """,""named"":false},{""type"":""ClassExprWidget"",""name" &
     "d"":true,""fields"":{""name"":{}}},{""type"":""import_wi" &
     "dget_binding"",""named"":true},{""type"":""import_thing_" &
     "declaration"",""named"":true},{""type"":""error_gadget_r" &
     "ef_specifier"",""named"":true,""fields"":{""name"":{}}}," &
     "{""type"":""NamespaceGadgetValueItem"",""named"":true},{" &
     """type"":""TraitNodeExprDef"",""named"":true},{""type"":" &
     """ListDecl"",""named"":true,""fields"":{""name"":{}}},{""" &
     "type"":""type__binding"",""named"":true},{""type"":""dec" &
     "l"",""named"":true},{""type"":""StructGadget_binding"",""" &
     "named"":true,""fields"":{""name"":{}}},{""type"":""NAMES" &
     "PACE__BINDING"",""named"":false},{""type"":""ParameterBo" &
     "dyDeclaration"",""named"":true},{""type"":""TestDef"",""" &
     "named"":true,""fields"":{""name"":{}}},{""type"":""var_i" &
     "tem_spec_item"",""named"":true},{""type"":""struct_thing" &
     "_definition"",""named"":true},{""type"":""type_list_decl" &
     "aration"",""named"":true,""fields"":{""name"":{}}},{""ty" &
     "pe"":""EnumDecl"",""named"":true},{""type"":""ref_node__" &
     "specifier"",""named"":true},{""type"":""ValueThingItem""" &
     ",""named"":true,""fields"":{""name"":{}}},{""type"":""Wi" &
     "dgetRefDeclaration"",""named"":true},{""type"":""Decl""," &
     """named"":true},{""type"":""struct_gadget_def"",""named""" &
     ":false,""fields"":{""name"":{}}},{""type"":""module_body" &
     "__binding"",""named"":true},{""type"":""enum_expr_gadget" &
     "__binding"",""named"":true},{""type"":""struct"",""named" &
     """:true,""fields"":{""name"":{}}},{""type"":""ConstTypeD" &
     "eclaration"",""named"":true},{""type"":""widget_body_dec" &
     "l"",""named"":true},{""type"":""NamespaceThingDefinition" &
     """,""named"":true,""fields"":{""name"":{}}},{""type"":""" &
     "ITEM_TYPE"",""named"":true},{""type"":""ModuleWidgetItem" &
     """,""named"":true},{""type"":""struct_value_widget__item" &
     """,""named"":true,""fields"":{""name"":{}}},{""type"":""" &
     "SpecSpecifier"",""named"":true},{""type"":""body_type_de" &
     "f"",""named"":false},{""type"":""NameGadget_binding"",""" &
     "named"":true,""fields"":{""name"":{}}},{""type"":""varia" &
     "ble_thing"",""named"":true},{""type"":""VarExprGadget""," &
     """named"":true},{""type"":""class_gadget_declaration"",""" &
     "named"":true,""fields"":{""name"":{}}},{""type"":""widge" &
     "t_type"",""named"":true},{""type"":""package_decl"",""na" &
     "med"":true},{""type"":""error_item_thing"",""named"":tru" &
     "e,""fields"":{""name"":{}}},{""type"":""VARIABLE_BODY_TY" &
     "PE_DEF"",""named"":true},{""type"":""interface_item"",""" &
     "named"":true},{""type"":""VarWidgetWidgetSpecifier"",""n" &
     "amed"":true,""fields"":{""name"":{}}},{""type"":""interf" &
     "ace_name_widget_definition"",""named"":false},{""type"":" &
     """ThingDeclaration"",""named"":true},{""type"":""var_gad" &
     "get_definition"",""named"":true,""fields"":{""name"":{}}" &
     "},{""type"":""param_widget_ref__item"",""named"":true},{" &
     """type"":""class_node_item_definition"",""named"":true}," &
     "{""type"":""container_ref_decl"",""named"":true,""fields" &
     """:{""name"":{}}},{""type"":""Specifier"",""named"":true" &
     "},{""type"":""expr_type__specifier"",""named"":true},{""" &
     "type"":""VarWidgetWidgetDecl"",""named"":true,""fields""" &
     ":{""name"":{}}},{""type"":""namespace_type_item__binding" &
     """,""named"":true},{""type"":""class_type_expr_item"",""" &
     "named"":true},{""type"":""TestSpecItem_specifier"",""nam" &
     "ed"":false,""fields"":{""name"":{}}},{""type"":""WidgetW" &
     "idgetDeclaration"",""named"":true},{""type"":""TestThing" &
     "RefDecl"",""named"":true},{""type"":""widget__item"",""n" &
     "amed"":true,""fields"":{""name"":{}}},{""type"":""variab" &
     "le_ref_widget"",""named"":true},{""type"":""ExprThingDef" &
     """,""named"":true},{""type"":""error_declaration"",""nam" &
     "ed"":true,""fields"":{""name"":{}}},{""type"":""WidgetBi" &
     "nding"",""named"":true},{""type"":""node_thing_item"",""" &
     "named"":true},{""type"":""_ITEM"",""named"":true,""field" &
     "s"":{""name"":{}}},{""type"":""WIDGET_DEFINITION"",""nam" &
     "ed"":true},{""type"":""ModuleDecl"",""named"":false},{""" &
     "type"":""ClassDef"",""named"":true,""fields"":{""name"":" &
     "{}}},{""type"":""RefDeclaration"",""named"":true},{""typ" &
     "e"":""ImportBinding"",""named"":true},{""type"":""import" &
     "_declaration"",""named"":true,""fields"":{""name"":{}}}," &
     "{""type"":""gadget_declaration"",""named"":true},{""type" &
     """:""namespace_widget_decl"",""named"":true},{""type"":""" &
     "package_spec_ref_item"",""named"":true,""fields"":{""nam" &
     "e"":{}}},{""type"":""widget"",""named"":true},{""type"":" &
     """ExprExprDef"",""named"":true},{""type"":""body_def"",""" &
     "named"":true,""fields"":{""name"":{}}},{""type"":""type_" &
     "ref__binding"",""named"":false},{""type"":""error_item""" &
     ",""named"":true},{""type"":""var_name"",""named"":true,""" &
     "fields"":{""name"":{}}},{""type"":""const_type_name_spec" &
     "ifier"",""named"":true},{""type"":""interface__item"",""" &
     "named"":true},{""type"":""ParamNameBodyBinding"",""named" &
     """:true,""fields"":{""name"":{}}},{""type"":""enum_speci" &
     "fier"",""named"":true},{""type"":""VariableValueWidgetDe" &
     "cl"",""named"":true},{""type"":""REF_TYPE_DECL"",""named" &
     """:true,""fields"":{""name"":{}}},{""type"":""interface_" &
     "widget_item"",""named"":true},{""type"":""ThingValueDefi" &
     "nition"",""named"":true},{""type"":""ERROR_THING_DECLARA" &
     "TION"",""named"":false,""fields"":{""name"":{}}},{""type" &
     """:""error_expr_thing__specifier"",""named"":true},{""ty" &
     "pe"":""variable__item"",""named"":true},{""type"":""para" &
     "meter_spec"",""named"":true,""fields"":{""name"":{}}},{""" &
     "type"":""test_expr_value_decl"",""named"":true},{""type""" &
     ":""class_value_item_def"",""named"":true},{""type"":""pa" &
     "ckage_type"",""named"":true,""fields"":{""name"":{}}},{""" &
     "type"":""ListWidgetBinding"",""named"":true},{""type"":""" &
     "NodeGadgetBinding"",""named"":true},{""type"":""Struct""" &
     ",""named"":true,""fields"":{""name"":{}}},{""type"":""st" &
     "ruct_type"",""named"":true},{""type"":""structure_declar" &
     "ation"",""named"":false},{""type"":""StructureDecl"",""n" &
     "amed"":true,""fields"":{""name"":{}}},{""type"":""classy" &
     "_declaration"",""named"":true},{""type"":""ClassDecl"",""" &
     "named"":true},{""type"":""class"",""named"":true,""field" &
     "s"":{""name"":{}}},{""type"":""var_def"",""named"":true}" &
     ",{""type"":""Variable"",""named"":true},{""type"":""varD" &
     "ecl"",""named"":true,""fields"":{""name"":{}}},{""type""" &
     ":""testing_def"",""named"":true},{""type"":""errors_item" &
     """,""named"":true},{""type"":""import_binding"",""named""" &
     ":true,""fields"":{""name"":{}}}]";

   Generated_Expected : constant String :=
     "NAMESPACE_WIDGET_DEF:namespace:N;PackageWidgetItemDeclar" &
     "ation:namespace:Y;Def:function:N;struct_ref_decl:struct:" &
     "Y;node_name_item:function:Y;TestTypeName_item:test:N;pac" &
     "kage_gadget_definition:namespace:N;ImportDeclaration:nam" &
     "espace:N;type_list__specifier:function:Y;_item:function:" &
     "N;body_list_def:function:N;StructGadgetGadgetDeclaration" &
     ":struct:Y;SpecDeclaration:function:N;gadget_ref_def:func" &
     "tion:N;widget_ref_def:function:N;param_value_ref_item:pa" &
     "rameter:Y;list_value_decl:function:N;list_type__item:fun" &
     "ction:N;interface_decl:interface:Y;variable_node_decl:va" &
     "r:N;node_node__specifier:function:N;enum_gadget__item:en" &
     "um:Y;BODY_BODY__ITEM:function:N;name__binding:function:N" &
     ";ModuleValueThingDecl:module:N;widget_def:function:N;Mod" &
     "uleValueDeclaration:module:Y;VariableDeclaration:var:N;c" &
     "onst_type_expr_declaration:constant:N;Definition:functio" &
     "n:Y;def:function:N;LIST_DEFINITION:function:Y;gadget_ref" &
     "__specifier:function:N;module_name_expr_item:module:N;St" &
     "ructGadgetRefDeclaration:struct:Y;ref__specifier:functio" &
     "n:N;error_item_def:type:Y;interface_ref__specifier:inter" &
     "face:N;TestNodeGadgetDeclaration:test:N;namespace_spec_d" &
     "eclaration:namespace:N;ref_binding:function:N;test_node_" &
     "def:test:N;_binding:function:Y;gadget_node_decl:function" &
     ":N;_specifier:function:Y;TraitNameRef_item:trait:N;Class" &
     "ListDefinition:class:Y;test_list_declaration:test:N;para" &
     "meter_ref_definition:parameter:Y;thing_type__specifier:f" &
     "unction:N;gadget_widget__binding:function:Y;body_node_de" &
     "claration:function:N;module_spec_list_specifier:module:N" &
     ";const_ref_ref_definition:constant:Y;EnumBodyWidgetDecla" &
     "ration:enum:N;node_definition:function:N;parameter_widge" &
     "t_declaration:parameter:Y;NodeDefinition:function:N;Cont" &
     "ainerItemDecl:type:Y;import_definition:namespace:N;widge" &
     "t_decl:function:Y;VariableDecl:var:N;enum__binding:enum:" &
     "N;ContainerBodyWidget_specifier:type:Y;ParameterRefValue" &
     "Def:parameter:N;interface_gadget__binding:interface:N;im" &
     "port_gadget_declaration:namespace:N;value_spec__item:fun" &
     "ction:N;item_ref_item:function:Y;namespace_decl:namespac" &
     "e:N;VarSpecItemDecl:var:Y;container_value_item:type:N;na" &
     "mespace_expr__binding:namespace:N;StructSpecSpecDecl:str" &
     "uct:N;CONST_TYPE__BINDING:constant:N;var_list__binding:v" &
     "ar:Y;definition:function:N;trait_expr_widget_def:trait:Y" &
     ";interface_node_item:interface:N;interface_body_binding:" &
     "interface:N;list__item:function:N;VariableValueGadgetDec" &
     "laration:var:N;struct_declaration:struct:N;InterfaceDefi" &
     "nition:interface:N;ParameterBodyExprDeclaration:paramete" &
     "r:N;widget_gadget_specifier:function:Y;value_declaration" &
     ":function:N;ParamBodyDef:parameter:N;struct_decl:struct:" &
     "Y;CONTAINER_NAME__ITEM:type:N;container_body_specifier:t" &
     "ype:N;interface_specifier:interface:Y;import_widget_bind" &
     "ing:namespace:N;import_thing_declaration:namespace:N;err" &
     "or_gadget_ref_specifier:type:Y;TraitNodeExprDef:trait:N;" &
     "ListDecl:function:Y;type__binding:function:N;decl:functi" &
     "on:N;StructGadget_binding:struct:Y;ParameterBodyDeclarat" &
     "ion:parameter:N;TestDef:test:Y;var_item_spec_item:var:N;" &
     "struct_thing_definition:struct:N;type_list_declaration:f" &
     "unction:Y;EnumDecl:enum:N;ref_node__specifier:function:N" &
     ";WidgetRefDeclaration:function:N;Decl:function:N;module_" &
     "body__binding:module:N;enum_expr_gadget__binding:enum:N;" &
     "ConstTypeDeclaration:constant:N;widget_body_decl:functio" &
     "n:N;NamespaceThingDefinition:namespace:Y;struct_value_wi" &
     "dget__item:struct:Y;NameGadget_binding:function:Y;class_" &
     "gadget_declaration:class:Y;package_decl:namespace:N;VARI" &
     "ABLE_BODY_TYPE_DEF:var:N;interface_item:interface:N;Thin" &
     "gDeclaration:function:N;var_gadget_definition:var:Y;para" &
     "m_widget_ref__item:parameter:N;class_node_item_definitio" &
     "n:class:N;container_ref_decl:type:Y;expr_type__specifier" &
     ":function:N;VarWidgetWidgetDecl:var:Y;namespace_type_ite" &
     "m__binding:namespace:N;class_type_expr_item:class:N;Widg" &
     "etWidgetDeclaration:function:N;TestThingRefDecl:test:N;w" &
     "idget__item:function:Y;ExprThingDef:function:N;error_dec" &
     "laration:type:Y;node_thing_item:function:N;_ITEM:functio" &
     "n:Y;WIDGET_DEFINITION:function:N;ClassDef:class:Y;RefDec" &
     "laration:function:N;import_declaration:namespace:Y;gadge" &
     "t_declaration:function:N;namespace_widget_decl:namespace" &
     ":N;package_spec_ref_item:namespace:Y;ExprExprDef:functio" &
     "n:N;body_def:function:Y;error_item:type:N;const_type_nam" &
     "e_specifier:constant:N;interface__item:interface:N;enum_" &
     "specifier:enum:N;VariableValueWidgetDecl:var:N;REF_TYPE_" &
     "DECL:function:Y;interface_widget_item:interface:N;ThingV" &
     "alueDefinition:function:N;error_expr_thing__specifier:ty" &
     "pe:N;variable__item:var:N;test_expr_value_decl:test:N;cl" &
     "ass_value_item_def:class:N;StructureDecl:function:Y;clas" &
     "sy_declaration:function:N;ClassDecl:class:N;var_def:var:" &
     "N;varDecl:var:Y;testing_def:function:N;errors_item:funct" &
     "ion:N;import_binding:namespace:Y;";

   procedure A_Generated_Listing_Matches_An_Independent_Implementation
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant String := Classified (Generated_Json);
   begin
      Assert
        (Got'Length = Generated_Expected'Length,
         "the same length: " & Natural'Image (Got'Length) & " vs" &
         Natural'Image (Generated_Expected'Length));
      Assert (Got = Generated_Expected, "every type, kind and name field");
   end A_Generated_Listing_Matches_An_Independent_Implementation;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Node_Types");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Anonymous_Type_Is_Never_A_Declaration'Access,
         "An anonymous type is never a declaration");
      Register_Routine
        (T, A_Plain_Node_With_No_Declaration_Name_Is_Skipped'Access,
         "A plain node with no declaration name is skipped");
      Register_Routine
        (T, A_Suffix_With_No_Prefix_Word_Gets_The_Generic_Kind'Access,
         "A suffix with no prefix word gets the generic kind");
      Register_Routine
        (T, A_Prefix_Word_Becomes_The_Kind'Access,
         "A prefix word becomes the kind");
      Register_Routine
        (T, Prefix_Words_Map_To_The_Kinds_A_Grammars_Locals_Use'Access,
         "Prefix words map to the kinds a grammar's locals use");
      Register_Routine
        (T, A_Prefix_Word_Must_Land_On_A_Boundary'Access,
         "A prefix word must land on a boundary");
      Register_Routine
        (T, Declaration_Suffixes_Match_In_Any_Case'Access,
         "Declaration suffixes match in any case");
      Register_Routine
        (T, A_Bare_Prefix_Word_Is_Not_A_Declaration'Access,
         "A bare prefix word is not a declaration");
      Register_Routine
        (T, A_Type_With_No_Fields_Has_No_Name_Field'Access,
         "A type with no fields has no name field");
      Register_Routine
        (T, A_Non_Array_Classifies_To_Nothing_And_Bad_Json_Is_Refused'Access,
         "A non-array classifies to nothing and bad JSON is refused");
      Register_Routine
        (T, A_Rule_Names_A_Type_The_Heuristic_Misses'Access,
         "A rule names a type the heuristic misses");
      Register_Routine
        (T, A_Rule_Relabels_A_Type_The_Heuristic_Caught'Access,
         "A rule relabels a type the heuristic caught");
      Register_Routine
        (T, The_Query_Has_One_Pattern_Per_Named_Guess'Access,
         "The query has one pattern per named guess");
      Register_Routine
        (T, A_Generated_Listing_Matches_An_Independent_Implementation'Access,
         "A generated listing matches an independent implementation");
   end Register_Tests;

end Synapse.Core.Node_Types.Tests;
