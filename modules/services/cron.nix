# services.cron – Scheduled tasks via supercronic (cron for containers).
#
# Uses supercronic instead of traditional cron because it:
# - Runs in the foreground (no daemon fork)
# - Logs to stdout/stderr (container-friendly)
# - Supports standard crontab syntax
{ lib, pkgs, config, ... }:

let
  cfg = config.services.cron;

  crontab = pkgs.writeText "crontab" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: job:
        "# ${name}\n${job.schedule} ${job.command}"
      ) cfg.jobs
    ) + "\n"
  );
in
{
  options.services.cron = {
    enable = lib.mkEnableOption "cron scheduler (supercronic)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.supercronic;
      description = "The supercronic package to use.";
    };

    jobs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          schedule = lib.mkOption {
            type = lib.types.str;
            example = "*/5 * * * *";
            description = "Cron schedule expression.";
          };
          command = lib.mkOption {
            type = lib.types.str;
            example = "curl -s http://localhost:8080/health";
            description = "Command to run.";
          };
        };
      });
      default = {};
      description = "Named cron jobs.";
    };

    crontabFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Override with a custom crontab file. If set, jobs are ignored.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ cfg.package ];

    files = [
      {
        source = if cfg.crontabFile != null then cfg.crontabFile else crontab;
        target = "etc/crontab";
      }
    ];

    s6Services.cron = {
      kind = "longrun";
      run = ''
        exec ${cfg.package}/bin/supercronic /etc/crontab
      '';
    };
  };
}
