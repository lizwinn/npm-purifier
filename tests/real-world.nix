# SPDX-License-Identifier: MIT
#
# Real projects, pinned to a commit, built the way their developers build
# them: `npm ci`, the build scripts and the test suite, in the sandbox.
#
#   commander   commander.js, a library with TypeScript typings; its test
#               script runs Node's test runner, tsd and the TypeScript
#               compiler
#   httpServer  http-server, a command with a tap test suite. Its
#               package-lock.json leaves the tarball URL and the integrity
#               of 130 entries out. The build keeps its npm-purifier.lock.json
#               outside the project (real-world/http-server), as a flake
#               that packages a project without changing it does, and
#               `npm-purifier lock --lockfile` recorded the 130 entries
#               there.
#
# The sources are fetched at evaluation time with a pinned hash, so the
# builder reads their lockfiles without import-from-derivation.
{ buildNpmProject }:
{
  commander = buildNpmProject {
    src = builtins.fetchTarball {
      url = "https://github.com/tj/commander.js/archive/ba6d13ddb4243e5913367734f8c159089ffe7834.tar.gz";
      sha256 = "02nkyin3d4lb1b11hl8djcjw48dbm201yipk9zlyxc1pslskl4gm";
    };
    doCheck = true;
  };

  httpServer = buildNpmProject {
    src = builtins.fetchTarball {
      url = "https://github.com/http-party/http-server/archive/0d3b7bb5b6e8a59fd450ae2dca65870009cfcd8b.tar.gz";
      sha256 = "0xv5aa4y47jz6cxjx97q64nwn2zh7ddsyhcda6f2qglxx3iycc7n";
    };
    # The project's package-lock.json leaves out the URL and integrity of
    # many entries. `npm-purifier lock --lockfile` recorded them in this
    # file, kept outside the project.
    lockFile = ./real-world/http-server/npm-purifier.lock.json;
    doCheck = true;
    # Two of the test files listen on port 8000; tap runs them one after
    # the other with one job.
    checkFlags = [ "--jobs=1" ];
  };
}
