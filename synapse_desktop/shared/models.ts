// What the name of a model looks like, which the server and the page both hold a name to: it
// starts with a letter or a digit, so that it cannot be taken for a flag, and holds what the
// names of models are made of, which includes the brackets of an alias such as `sonnet[1m]`.
export const MODEL_NAME = /^[A-Za-z0-9][A-Za-z0-9._:/@+~[\]-]{0,199}$/
