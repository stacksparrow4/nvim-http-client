{
  pkgs ? import <nixpkgs> { },
  python3 ? pkgs.python3,
}:

let
  pythonEnv = import ./python-env.nix { inherit pkgs python3; };
in
pkgs.stdenv.mkDerivation {
  pname = "send-request";
  version = "0.1.0";

  src = ./python;

  dontBuild = true;
  doCheck = false;

  installPhase = ''
    runHook preInstall

    install -D send_request.py $out/bin/send-request

    substituteInPlace $out/bin/send-request \
      --replace-fail \
        '#!/usr/bin/env -S uv run --script' \
        '#!${pythonEnv}/bin/python3'

    runHook postInstall
  '';
}
