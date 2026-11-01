const isNumber = require("is-number");

module.exports = (name) =>
  isNumber(name) ? `hello, number ${name}` : `hello, ${name}`;
