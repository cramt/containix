{
  description = "containix – a mini NixOS for containers";

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
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;
      nix2containerPkgs = nix2container.packages.${system};

      # npins sources – read the raw JSON so we get url+hash for fetchurl,
      # rather than using npins' default.nix which unpacks tarballs.
      sources = (builtins.fromJSON (builtins.readFile ./npins/sources.json)).pins;

      mkS6RcImage = import ./mk-s6rc-image.nix { inherit pkgs nix2containerPkgs sources; };

      # Auto-discover service modules from modules/services/
      serviceModuleDir = ./modules/services;
      serviceModules =
        lib.optionalAttrs (builtins.pathExists serviceModuleDir)
          (builtins.readDir serviceModuleDir);
      serviceModuleList =
        lib.mapAttrsToList
          (name: _: import (serviceModuleDir + "/${name}"))
          serviceModules;

      # All modules: base + all service modules
      allModules = [ ./modules/default.nix ] ++ serviceModuleList;

      # mkContainer :: config -> image derivation
      # Evaluates the module system and calls mkS6RcImage with the result.
      mkContainer = config: let
        evaluated = (lib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = allModules ++ [
            ({ ... }: config)
          ];
        }).config;
      in
        mkS6RcImage {
          name = evaluated.image.name;
          tag = evaluated.image.tag;
          user = evaluated.image.user;
          env = evaluated.environment;
          extraPaths = evaluated.packages;
          copyToRoot = evaluated.copyToRoot;
          extraFiles = evaluated.files;
          services = lib.mapAttrs (_: svc:
            { inherit (svc) kind after; }
            // lib.optionalAttrs (svc.run != null) { inherit (svc) run; }
            // lib.optionalAttrs (svc.up != null) { inherit (svc) up; }
            // lib.optionalAttrs (svc.down != null) { inherit (svc) down; }
          ) evaluated.s6Services;
        };
    in {
      lib = {
        inherit mkS6RcImage mkContainer;
      };
    });
}
