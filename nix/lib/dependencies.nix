# SPDX-License-Identifier: MIT
#
# The fetched downloads of a lock, laid out as a tree: each download's
# file lies at its `path`, as a link to its fixed-output fetch. For npm the
# tree is the content of a cache, which a build links in as
# $npm_config_cache/_cacache/content-v2.
#
# This file knows nothing of npm: it takes download entries of the shape
# { path, url, mirrors, hash } and nothing else. `mirrors` lists other URLs
# that serve the same file.
{
  lib,
  runCommand,
  fetchurl,
  # The download entries.
  downloads,
  # The name of the tree in the store.
  name ? "npm-purifier-dependencies",
}:
let
  # A store name allows fewer characters than a URL; the last segment of
  # the URL, with the rest replaced, keeps the store listing readable.
  storeName =
    url:
    let
      base = lib.last (lib.splitString "/" (builtins.head (lib.splitString "?" url)));
      clean = builtins.replaceStrings [ "%" "@" "~" "!" ] [ "_" "_" "_" "_" ] base;
    in
    if clean == "" then "download" else clean;

  fetch =
    d:
    fetchurl {
      urls = [ d.url ] ++ d.mirrors;
      inherit (d) hash;
      name = storeName d.url;
    };
in
runCommand name
  {
    # The tree holds only links.
    preferLocalBuild = true;
    allowSubstitutes = false;
    passAsFile = [ "links" ];
    links = lib.concatMapStrings (d: "${d.path}\t${fetch d}\n") downloads;
  }
  ''
    mkdir -p "$out"
    while IFS=$'\t' read -r path target; do
      mkdir -p "$out/$(dirname "$path")"
      ln -s "$target" "$out/$path"
    done < "$linksPath"
  ''
