{
  pkgs ? import <nixpkgs> { },
  python3 ? pkgs.python3,
}:
python3.withPackages (ps: [
  ps.httpx
  ps.h2 # HTTP/2 support (httpx[http2])
  ps.socksio # SOCKS5 proxy support (httpx[socks])
  ps.brotli
  ps.zstandard
])
