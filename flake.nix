{
  description = "AltAltTab dev shell (uses system Swift from Command Line Tools, not nixpkgs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            name = "alt-alttab";

            # NOTE: We deliberately do NOT add `pkgs.swift` here. The Darwin
            # Swift toolchain in nixpkgs lags far behind (5.x) and cannot
            # target the macOS 26 SDK. Use the system Swift 6.x that ships
            # with Xcode Command Line Tools at /usr/bin/swift instead.
            packages = [
              pkgs.gnumake
              pkgs.ffmpeg   # デモ GIF 変換用 (make gif)
            ];

            shellHook = ''
              if /usr/bin/swift --version >/dev/null 2>&1; then
                : # system Swift found, all good
              else
                echo "warning: /usr/bin/swift not found or not working." >&2
                echo "         Install Xcode Command Line Tools with: xcode-select --install" >&2
              fi
            '';
          };
        });
    };
}
