#!/usr/bin/env node
const chalk = require("chalk");
const message = require("../dist/message.js");

console.log(chalk.green(`hello-npm: ${message}`));
