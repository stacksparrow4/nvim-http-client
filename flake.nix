{
  description = "HTTP request/response neovim plugin";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { nixpkgs, ... }: {

    packages.x86_64-linux.default = import ./default.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };

  };
}
