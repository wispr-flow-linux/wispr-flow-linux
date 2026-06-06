{
  description = "Wispr Flow voice dictation for Linux (unofficial)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      # The payload is the proprietary Wispr Flow app, so the derivation is
      # marked unfree. Import nixpkgs with an allowance scoped to just our
      # package names — consumers `nix build`-ing from this flake don't need to
      # set NIXPKGS_ALLOW_UNFREE themselves.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [
            "wispr-flow"
          ];
      };
    in
    {
      packages = forEachSystem (system:
        let
          pkgs = pkgsFor system;
          wispr-flow = pkgs.callPackage ./nix/wispr-flow.nix { };
          wispr-flow-fhs = pkgs.callPackage ./nix/fhs.nix { inherit wispr-flow; };
        in
        {
          inherit wispr-flow wispr-flow-fhs;
          # FHS wrapper is the recommended default (provides the glibc loader
          # Electron needs on NixOS).
          default = wispr-flow-fhs;
        });

      # Overlay so the packages can be consumed from another flake's nixpkgs.
      overlays.default = final: prev: let
        wispr-flow = final.callPackage ./nix/wispr-flow.nix { };
      in {
        inherit wispr-flow;
        wispr-flow-fhs = final.callPackage ./nix/fhs.nix { inherit wispr-flow; };
      };
    };
}
