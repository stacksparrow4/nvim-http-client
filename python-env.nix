{
  pkgs ? import <nixpkgs> { },
  python3 ? pkgs.python3,
}:
python3.withPackages (ps: [
  ps.requests
  ps.pysocks # SOCKS5 proxy support (requests[socks])
  ps.brotli
  ps.zstandard
])
