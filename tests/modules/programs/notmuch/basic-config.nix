{ config, lib, pkgs, ... }:

with lib;

{
  imports = [ ../../accounts/email-test-accounts.nix ];

  config = {
    home.username = "hm-user";
    home.homeDirectory = "/home/hm-user";

    programs.notmuch = {
      enable = true;
    };

    accounts.email.accounts = {
      "hm@example.com" = {
        notmuch.enable = true;
        primary = true;
      };

      hm-account.notmuch = {
        enable = true;
      };
    };

    nmt.script = ''
      assertFileExists home-files/.config/notmuch/notmuchrc
      assertFileContent home-files/.config/notmuch/notmuchrc \
        ${./basic-config-expected.conf}
    '';
  };
}
