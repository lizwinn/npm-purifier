#!/usr/bin/env node
console.log(`shared: ${require("@fixture/shared")}`);
console.log(`vendored: ${require("vendored")}`);
console.log(`is-odd: ${require("is-odd")(3)}`);
