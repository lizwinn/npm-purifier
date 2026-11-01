// Writes dist/message.js, which the package's command reads, so a package
// without it shows that the build script did not run.
const fs = require("fs");
const path = require("path");

const dist = path.join(__dirname, "..", "dist");
fs.mkdirSync(dist, { recursive: true });
fs.writeFileSync(
  path.join(dist, "message.js"),
  'module.exports = "built by the build script";\n',
);
