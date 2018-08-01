{ config, lib, pkgs, utils, ... }:

with lib;

let

  cfg = config.users;

  hmModule = types.submodule ({name, ...}: {
    imports = import ../modules/modules.nix {
      inherit lib pkgs;
      nixosSubmodule = true;
    };

    config = {
      home.username = cfg.users.${name}.name;
      home.homeDirectory = cfg.users.${name}.home;
    };
  });

in

{
  options = {
    users.users = mkOption {
      options = [
        {
          home-manager = mkOption {
            type = types.attrsOf hmModule;
            default = {};
            description = ''
              Per-user Home Manager configuration.
            '';
          };
        }
      ];
    };
  };

  config = {
    systemd.services = mapAttrs' (username: usercfg:
      nameValuePair ("home-manager-${utils.escapeSystemdPath username}") {
        description = "Home Manager environment for ${username}";
        wantedBy = [ "multi-user.target" ];
        wants = [ "nix-daemon.socket" ];
        after = [ "nix-daemon.socket" ];

        serviceConfig = {
          User = username;
          Type = "oneshot";
          RemainAfterExit = "yes";
          SyslogIdentifier = "hm-activate-${username}";

          # The activation script is run by a login shell to make sure
          # that the user is given a sane Nix environment.
          ExecStart = pkgs.writeScript "activate-${username}" ''
            #! ${pkgs.stdenv.shell} -el
            echo Activating home-manager configuration for ${username}
            exec ${usercfg.home-manager.home.activationPackage}/activate
          '';
        };
      }
    ) (filterAttrs (n: v: v ? home-manager) cfg.users);
  };
}
