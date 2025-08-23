{
  description = "api.re-zip.com";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nix2container = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nlewo/nix2container";
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    nix2container,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          (final: prev: {
            jeRuby = prev.ruby.override {
              jemallocSupport = true;
            };
          })
        ];
      };
      lib = pkgs.lib;
      nix2containerPkgs = nix2container.packages.${system};
      mkMultiRunContainer = {
        name,
        packages,
        packagesToRun,
      }: rec {
        entrypoint = pkgs.writeShellApplication {
          name = "entrypoint";
          runtimeEnv = {
          };
          runtimeInputs = [pkgs.multirun pkgs.bash] ++ packagesToRun;
          text = let
            commands = builtins.map lib.getExe packagesToRun;
          in ''
            multirun ${lib.strings.concatStringsSep " " (builtins.map (x: ''"${x}"'') commands)}
          '';
        };
        container = nix2containerPkgs.nix2container.buildImage {
          name = name;
          copyToRoot = [
            (pkgs.buildEnv {
              name = "root";
              paths = [entrypoint] ++ packages;
            })
          ];
          config = {
            Cmd = ["${entrypoint}/bin/entrypoint"];
          };
        };
      };
      modules = lib.attrsets.mapAttrsToList (name: value: (import ./modules/${name})) (builtins.readDir ./modules);
    in {
      packages = rec {
        mkContainer = config: let
          result =
            (pkgs.lib.evalModules {
              specialArgs = {
                pkgs = pkgs;
              };
              modules =
                modules
                ++ [
                  ({...}: config)
                ];
            }).config;
        in
          mkMultiRunContainer {
            name = result.name;
            packagesToRun = result.entrypoints;
            packages = result.packages ++ result.entrypoints;
          };
        grafana-test = mkContainer {
          name = "grafana";
          grafana-alloy.enable = true;
        };
      };
    });
}
