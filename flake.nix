{
  description = "HTTP request/response neovim plugin";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      systems = nixpkgs.lib.systems.flakeExposed;
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          nvim-http-client = import ./default.nix { inherit pkgs; };
          urlenc = import ./urlenc.nix { inherit pkgs; };
          send-request = import ./send-request.nix { inherit pkgs; };
          default = nvim-http-client;
        });
    };
}
