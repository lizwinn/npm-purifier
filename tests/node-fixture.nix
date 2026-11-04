# SPDX-License-Identifier: MIT
# Pinned upstream binaries for historical compatibility fixtures only.
{ pkgs, version }:
let
  archives = {
    "26.1.0-rc.0" = {
      x86_64-linux = {
        arch = "x64";
        sha256 = "5978e4e39892e1b51d9135efb72f7021d89fa0c57994d45f5e4af2a1e1fa931d";
      };
      aarch64-linux = {
        arch = "arm64";
        sha256 = "05f1f6d6eeadba773082ee47f6e75c95f109723ea31bea6cdeee3220b6b1533b";
      };
    };
    "12.22.12" = {
      x86_64-linux = {
        arch = "x64";
        sha256 = "e6d052364bfa2c17da92cf31794100cfd709ba147415ddaeed2222eec9ca1469";
      };
      aarch64-linux = {
        arch = "arm64";
        sha256 = "eebdeb528df727271635196188ed7d04a5dba2c61ccaded22f693ae501cf17f5";
      };
    };
    "4.9.1" = {
      x86_64-linux = {
        arch = "x64";
        sha256 = "db65d409f0fd7e4ff817509c7ec29df72f4b3f6885297b98f64781ecea92feea";
      };
      aarch64-linux = {
        arch = "arm64";
        sha256 = "7203f9693e06ad220cfde2e5d70778cb021a176ecab1bdfee0bf546363333f26";
      };
    };
    "0.12.18".x86_64-linux = {
      arch = "x64";
      sha256 = "5d18077263e6d43b95015adf968a17b312ead1a275f894d40494be61210fa91b";
    };
  };
  archive = archives.${version}.${pkgs.stdenv.hostPlatform.system};
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nodejs-legacy-fixture";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://nodejs.org/${
      if pkgs.lib.hasInfix "-rc." version then "download/rc" else "dist"
    }/v${version}/node-v${version}-linux-${archive.arch}.tar.xz";
    inherit (archive) sha256;
  };
  nativeBuildInputs = [ pkgs.patchelf ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  # Sorting this historical ELF's program headers makes it segfault before
  # main. Keep its order when installing the Nix loader and runtime libraries.
  dontPatchELF = true;
  installPhase = ''
    mkdir -p "$out"
    cp -r bin include lib share "$out/"
    patchelf --no-sort \
      --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} \
      --set-rpath ${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]} \
      "$out/bin/node"
    "$out/bin/node" --version
    export PATH="$out/bin:$PATH"
    patchShebangs "$out/lib/node_modules/npm"
  '';
}
