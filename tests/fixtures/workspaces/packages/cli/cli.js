#!/usr/bin/env node
// Prints a greeting from the workspace library and transforms a line of
// TypeScript with esbuild, whose native binary comes from a per-platform
// optional package.
const greeting = require("@fixture/greeting");
const esbuild = require("esbuild");

const { code } = esbuild.transformSync("let n: number = 1", { loader: "ts" });
console.log(`${greeting(process.argv[2] ?? "world")} (esbuild: ${code.trim()})`);
