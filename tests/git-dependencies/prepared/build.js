// The prepare script: it writes dist/index.js with the help of a dev
// dependency, so the dependency is installed before the script runs.
const fs = require("fs");
const path = require("path");
const isNumber = require("is-number");

fs.mkdirSync(path.join(__dirname, "dist"), { recursive: true });
fs.writeFileSync(
  path.join(__dirname, "dist", "index.js"),
  `module.exports = ${JSON.stringify(`prepared (is-number says ${isNumber(7)})`)};\n`,
);
