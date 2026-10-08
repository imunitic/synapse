module.exports = grammar({
  name: 'fake3',

  rules: {
    source_file: $ => repeat(choice($.function_declaration, $.struct_item)),

    function_declaration: $ => seq('fn', field('name', $.identifier), '(', ')'),

    struct_item: $ => seq('struct', $.identifier, '{', '}'),

    identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,
  }
});
