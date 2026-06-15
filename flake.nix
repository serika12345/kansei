{
  description = "Mission Control close-button overlay prototype for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [ ];
            shellHook = ''
              if [ -z "''${XCODE_DEVELOPER_DIR:-}" ]; then
                if [ -d /Applications/Xcode.app/Contents/Developer ]; then
                  export XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
                elif [ -x /usr/bin/xcode-select ]; then
                  export XCODE_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
                else
                  export XCODE_DEVELOPER_DIR=/Library/Developer/CommandLineTools
                fi
              fi

              export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
              export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
              export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
              echo "Run: swift run KanseiMissionClose"
              echo "App: scripts/build-app.sh release"
            '';
          };
        });
    };
}
