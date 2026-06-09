# Nix package for the nvim-http-client Neovim plugin.
#
# The plugin ships a Python helper (python/send_request.py) that, in its
# upstream form, is run via `uv run` and resolves its dependencies (requests,
# brotli, zstandard) on the fly. That is convenient for development but impure:
# it needs `uv` and network access at runtime.
#
# For a reproducible Nix build we instead bake a Python interpreter that
# already carries those dependencies and point the plugin's `runner` at it.
# This rewrite happens only inside the build sandbox (via substituteInPlace);
# the source tree on disk is left untouched.
#
# Build standalone:   nix-build
# Or via callPackage:  pkgs.callPackage ./default.nix { }
{
  pkgs ? import <nixpkgs> { },
  vimUtils ? pkgs.vimUtils,
  python3 ? pkgs.python3,
}:

let
  # Python environment with the helper's third-party dependencies.
  pythonEnv = python3.withPackages (ps: [
    ps.requests
    ps.brotli
    ps.zstandard
  ]);
in
vimUtils.buildVimPlugin {
  pname = "nvim-http-client";
  version = "0.1.0";

  src = ./.;

  # Drop build artifacts that may be lying around in the source tree.
  postPatch = ''
    rm -rf python/__pycache__ python/.venv

    # Pin the helper to our dependency-complete interpreter instead of
    # `uv run`, so no network access or `uv` is required at runtime.
    substituteInPlace lua/nvim-http-client/init.lua \
      --replace-fail \
        'runner = { "uv", "run" },' \
        'runner = { "${pythonEnv}/bin/python3" },'

    # Replace the uv inline-script shebang so the helper also works when run
    # directly, and so patchShebangs leaves a clean interpreter line.
    substituteInPlace python/send_request.py \
      --replace-fail \
        '#!/usr/bin/env -S uv run --script' \
        '#!${pythonEnv}/bin/python3'
  '';

  # Pure Lua/Python; nothing to compile or test here.
  doCheck = false;
}
