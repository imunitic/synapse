module.exports = grammar({
  name: 'fake_nested',

  rules: {
    source_file: $ => repeat(choice(
      $.wrapper_decl, $.shallow_decl, $.deep_decl, $.upper_decl, $.multi_decl,
      $.outer_decl,
    )),

    // Two guessed declarations around one identifier.
    wrapper_decl: $ => seq('wrap', $.var_decl),
    var_decl: $ => seq('var', $.identifier),

    // The identifier is three levels down: found. Four: not.
    shallow_decl: $ => seq('shallow', $.sa),
    sa: $ => seq('[', $.sb),
    sb: $ => seq('[', $.identifier),

    deep_decl: $ => seq('deep', $.da),
    da: $ => seq('<', $.db),
    db: $ => seq('<', $.dc),
    dc: $ => seq('<', $.identifier),

    // A name type spelled in capitals.
    upper_decl: $ => seq('upper', $.NAME),

    // A name that spans two lines.
    multi_decl: $ => seq('multi', $.name),

    // A declaration inside another.
    outer_decl: $ => seq('outer', $.identifier, '{', repeat($.inner_decl), '}'),
    inner_decl: $ => seq('inner', $.identifier),

    identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,
    NAME: $ => /[A-Z][A-Z0-9_]*/,
    name: $ => /[a-z]+\n[a-z]+/,
  }
});
