module.exports = grammar({
  name: 'fake_docstrings',

  extras: $ => [$.comment, /\s/],

  rules: {
    source_file: $ => repeat(choice($.function_declaration, $.struct_item)),

    function_declaration: $ => seq(
      'fn',
      field('name', $.identifier),
      '(',
      ')',
      optional(seq('{', repeat($.return_statement), '}')),
    ),

    struct_item: $ => seq('struct', field('name', $.identifier), '{', '}'),

    return_statement: $ => seq('return', ';'),

    identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,

    comment: $ => /\/\/[^\n]*/,
  }
});
