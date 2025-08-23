{lib, ...}: {
  options = {
    name = lib.mkOption {
      type = lib.types.str;
      description = ''
        The name of your container
      '';
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = ''
        The full list of programs to include
      '';
    };
    entrypoints = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = ''
        The full list of programs to run
      '';
    };
  };
}
