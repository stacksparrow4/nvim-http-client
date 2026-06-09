{
  description = "HTTP request/response neovim plugin";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: {

    packages.x86_64-linux.nvim-http-client = import ./default.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };

    packages.x86_64-linux.pwnproxy = import ./pwnproxy.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };
    
    packages.x86_64-linux.default = self.packages.x86_64-linux.nvim-http-client;

  };
}
