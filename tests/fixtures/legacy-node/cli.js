#!/usr/bin/env node
if (!require('is-number')(42)) process.exit(1);
console.log('42 on ' + process.version);
