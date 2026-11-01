#!/usr/bin/env node
// Loads every git dependency. The prepared ones exist only as their
// prepare scripts built them, and the cloned one carries its submodule.
const isNumber = require("is-number");
const prepared = require("npm-purifier-prepared-fixture");
const cloned = require("npm-purifier-clone-fixture");
require.resolve("remark-iptc-caption");

console.log(`is-number: ${isNumber(5)}`);
console.log(`prepared: ${prepared}`);
console.log(`clone: ${cloned}`);
console.log("remark-iptc-caption: installed");
