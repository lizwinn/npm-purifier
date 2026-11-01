# SPDX-License-Identifier: MIT
#
# The `npm-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildNpmProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    npm-purifier = prev.npm-purifier or { };
  };

}
