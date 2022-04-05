{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.programs.git;

  # create [section "subsection"] keys from "section.subsection" attrset names
  mkSectionName = name:
    let
      containsQuote = strings.hasInfix ''"'' name;
      sections = splitString "." name;
      section = head sections;
      subsections = tail sections;
      subsection = concatStringsSep "." subsections;
    in if containsQuote || subsections == [ ] then
      name
    else
      ''${section} "${subsection}"'';

  mkValueString = v:
    let
      escapedV = ''
        "${
          replaceStrings [ "\n" "	" ''"'' "\\" ] [ "\\n" "\\t" ''\"'' "\\\\" ] v
        }"'';
    in generators.mkValueStringDefault { } (if isString v then escapedV else v);

  # generation for multiple ini values
  mkKeyValue = k: v:
    let
      mkKeyValue =
        generators.mkKeyValueDefault { inherit mkValueString; } " = " k;
    in concatStringsSep "\n" (map (kv: "	" + mkKeyValue kv) (toList v));

  # converts { a.b.c = 5; } to { "a.b".c = 5; } for toINI
  gitFlattenAttrs = let
    recurse = path: value:
      if isAttrs value then
        mapAttrsToList (name: value: recurse ([ name ] ++ path) value) value
      else if length path > 1 then {
        ${concatStringsSep "." (reverseList (tail path))}.${head path} = value;
      } else {
        ${head path} = value;
      };
  in attrs: foldl recursiveUpdate { } (flatten (recurse [ ] attrs));

  gitToIni = attrs:
    let toIni = generators.toINI { inherit mkKeyValue mkSectionName; };
    in toIni (gitFlattenAttrs attrs);

  gitIniType = with types;
    let
      primitiveType = either str (either bool int);
      multipleType = either primitiveType (listOf primitiveType);
      sectionType = attrsOf multipleType;
      supersectionType = attrsOf (either multipleType sectionType);
    in attrsOf supersectionType;

  signModule = types.submodule {
    options = {
      key = mkOption {
        type = types.nullOr types.str;
        description = ''
          The default GPG signing key fingerprint.
          </para><para>
          Set to <literal>null</literal> to let GnuPG decide what signing key
          to use depending on commit’s author.
        '';
      };

      signByDefault = mkOption {
        type = types.bool;
        default = false;
        description = "Whether commits should be signed by default.";
      };

      gpgPath = mkOption {
        type = types.str;
        default = "${pkgs.gnupg}/bin/gpg2";
        defaultText = "\${pkgs.gnupg}/bin/gpg2";
        description = "Path to GnuPG binary to use.";
      };
    };
  };

  includeModule = types.submodule ({ config, ... }: {
    options = {
      condition = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Include this configuration only when <varname>condition</varname>
          matches. Allowed conditions are described in
          <citerefentry>
            <refentrytitle>git-config</refentrytitle>
            <manvolnum>1</manvolnum>
          </citerefentry>.
        '';
      };

      path = mkOption {
        type = with types; either str path;
        description = "Path of the configuration file to include.";
      };

      contents = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        example = literalExpression ''
          {
            user = {
              email = "bob@work.example.com";
              name = "Bob Work";
              signingKey = "1A2B3C4D5E6F7G8H";
            };
            commit = {
              gpgSign = true;
            };
          };
        '';
        description = ''
          Configuration to include. If empty then a path must be given.

          This follows the configuration structure as described in
          <citerefentry>
            <refentrytitle>git-config</refentrytitle>
            <manvolnum>1</manvolnum>
          </citerefentry>.
        '';
      };
    };

    config.path = mkIf (config.contents != { })
      (mkDefault (pkgs.writeText "contents" (gitToIni config.contents)));
  });

in {
  meta.maintainers = [ maintainers.rycee ];

  options = {
    programs.git = {
      enable = mkEnableOption "Git";

      package = mkOption {
        type = types.package;
        default = pkgs.git;
        defaultText = literalExpression "pkgs.git";
        description = ''
          Git package to install. Use <varname>pkgs.gitAndTools.gitFull</varname>
          to gain access to <command>git send-email</command> for instance.
        '';
      };

      userName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Default user name to use.";
      };

      userEmail = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Default user email to use.";
      };

      aliases = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { co = "checkout"; };
        description = "Git aliases to define.";
      };

      signing = mkOption {
        type = types.nullOr signModule;
        default = null;
        description = "Options related to signing commits using GnuPG.";
      };

      extraConfig = mkOption {
        type = types.either types.lines gitIniType;
        default = { };
        example = {
          core = { whitespace = "trailing-space,space-before-tab"; };
          url."ssh://git@host".insteadOf = "otherhost";
        };
        description = ''
          Additional configuration to add. The use of string values is
          deprecated and will be removed in the future.
        '';
      };

      iniContent = mkOption {
        type = gitIniType;
        internal = true;
      };

      ignores = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "*~" "*.swp" ];
        description = "List of paths that should be globally ignored.";
      };

      attributes = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "*.pdf diff=pdf" ];
        description = "List of defining attributes set globally.";
      };

      includes = mkOption {
        type = types.listOf includeModule;
        default = [ ];
        example = literalExpression ''
          [
            { path = "~/path/to/config.inc"; }
            {
              path = "~/path/to/conditional.inc";
              condition = "gitdir:~/src/dir";
            }
          ]
        '';
        description = "List of configuration files to include.";
      };

      lfs = {
        enable = mkEnableOption "Git Large File Storage";

        skipSmudge = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Skip automatic downloading of objects on clone or pull.
            This requires a manual <command>git lfs pull</command>
            every time a new commit is checked out on your repository.
          '';
        };
      };

      difftastic = {
        enable = mkEnableOption "" // {
          description = ''
            Enable the <command>difft</command> syntax highlighter.
            See <link xlink:href="https://github.com/Wilfred/difftastic" />.
          '';
        };

        background = mkOption {
          type = types.enum [ "light" "dark" ];
          default = "light";
          example = "dark";
          description = ''
            Determines whether difftastic should use the lighter or darker colors
            for syntax highlithing.
          '';
        };

        color = mkOption {
          type = types.enum [ "always" "auto" "never" ];
          default = "auto";
          example = "always";
          description = ''
            Determines when difftastic should color its output.
          '';
        };
      };

      delta = {
        enable = mkEnableOption "" // {
          description = ''
            Whether to enable the <command>delta</command> syntax highlighter.
            See <link xlink:href="https://github.com/dandavison/delta" />.
          '';
        };

        options = mkOption {
          type = with types;
            let
              primitiveType = either str (either bool int);
              sectionType = attrsOf primitiveType;
            in attrsOf (either primitiveType sectionType);
          default = { };
          example = {
            features = "decorations";
            whitespace-error-style = "22 reverse";
            decorations = {
              commit-decoration-style = "bold yellow box ul";
              file-style = "bold yellow ul";
              file-decoration-style = "none";
            };
          };
          description = ''
            Options to configure delta.
          '';
        };
      };

      diff-so-fancy = {
        enable = mkEnableOption "" // {
          description = ''
            Whether to enable the <command>diff-so-fancy</command> syntax
            highlighter. See <link xlink:href="https://github.com/so-fancy/diff-so-fancy" />.
          '';
        };

        options = mkOption {
          type = with types;
            let
              primitiveType = either str (either bool int);
              sectionType = attrsOf primitiveType;
            in attrsOf (either primitiveType sectionType);
          default = { };
          example = {
            markEmptyLines = false;
            changeHunkIndicators = false;
            rulerWidth = 47;
          };
          description = ''
            Options to configure diff-so-fancy.
          '';
        };
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      home.packages = [ cfg.package ];
      assertions = [{
        assertion = !(cfg.delta.enable && cfg.difftastic.enable);
        message = "Only one of 'programs.git.delta.enable', 'programs.git.difftastic.enable', or 'programs.git.diff-so-fancy.enable' can be set to true at the same time.";
      }];

      programs.git.iniContent.user = {
        name = mkIf (cfg.userName != null) cfg.userName;
        email = mkIf (cfg.userEmail != null) cfg.userEmail;
      };

      xdg.configFile = {
        "git/config".text = gitToIni cfg.iniContent;

        "git/ignore" = mkIf (cfg.ignores != [ ]) {
          text = concatStringsSep "\n" cfg.ignores + "\n";
        };

        "git/attributes" = mkIf (cfg.attributes != [ ]) {
          text = concatStringsSep "\n" cfg.attributes + "\n";
        };
      };
    }

    {
      programs.git.iniContent = let
        hasSmtp = name: account: account.smtp != null;

        genIdentity = name: account:
          with account;
          nameValuePair "sendemail.${name}" (if account.msmtp.enable then {
            smtpServer = "${pkgs.msmtp}/bin/msmtp";
            envelopeSender = "auto";
            from = address;
          } else
            {
              smtpEncryption = if smtp.tls.enable then
                (if smtp.tls.useStartTls
                || versionOlder config.home.stateVersion "20.09" then
                  "tls"
                else
                  "ssl")
              else
                "";
              smtpSslCertPath =
                mkIf smtp.tls.enable (toString smtp.tls.certificatesFile);
              smtpServer = smtp.host;
              smtpUser = userName;
              from = address;
            } // optionalAttrs (smtp.port != null) {
              smtpServerPort = smtp.port;
            });
      in mapAttrs' genIdentity
      (filterAttrs hasSmtp config.accounts.email.accounts);
    }

    (mkIf (cfg.signing != null) {
      programs.git.iniContent = {
        user.signingKey = mkIf (cfg.signing.key != null) cfg.signing.key;
        commit.gpgSign = cfg.signing.signByDefault;
        gpg.program = cfg.signing.gpgPath;
      };
    })

    (mkIf (cfg.aliases != { }) { programs.git.iniContent.alias = cfg.aliases; })

    (mkIf (lib.isAttrs cfg.extraConfig) {
      programs.git.iniContent = cfg.extraConfig;
    })

    (mkIf (lib.isString cfg.extraConfig) {
      warnings = [''
        Using programs.git.extraConfig as a string option is
        deprecated and will be removed in the future. Please
        change to using it as an attribute set instead.
      ''];

      xdg.configFile."git/config".text = cfg.extraConfig;
    })

    (mkIf (cfg.includes != [ ]) {
      xdg.configFile."git/config".text = let
        include = i:
          with i;
          if condition != null then {
            includeIf.${condition}.path = "${path}";
          } else {
            include.path = "${path}";
          };
      in mkAfter
      (concatStringsSep "\n" (map gitToIni (map include cfg.includes)));
    })

    (mkIf cfg.lfs.enable {
      home.packages = [ pkgs.git-lfs ];

      programs.git.iniContent.filter.lfs =
        let skipArg = optional cfg.lfs.skipSmudge "--skip";
        in {
          clean = "git-lfs clean -- %f";
          process =
            concatStringsSep " " ([ "git-lfs" "filter-process" ] ++ skipArg);
          required = true;
          smudge = concatStringsSep " "
            ([ "git-lfs" "smudge" ] ++ skipArg ++ [ "--" "%f" ]);
        };
    })

    (mkIf cfg.difftastic.enable {
      home.packages = [ pkgs.difftastic ];

      programs.git.iniContent = let
        difftCommand =
          "${pkgs.difftastic}/bin/difft --color ${cfg.difftastic.color} --background ${cfg.difftastic.background}";
      in {
        diff.external = difftCommand;
        core.pager = "${pkgs.less}/bin/less -XF";
      };
    })

    (mkIf cfg.delta.enable {
      home.packages = [ pkgs.delta ];

      programs.git.iniContent = let deltaCommand = "${pkgs.delta}/bin/delta";
      in {
        core.pager = deltaCommand;
        interactive.diffFilter = "${deltaCommand} --color-only";
        delta = cfg.delta.options;
      };
    })

    (mkIf cfg.diff-so-fancy.enable {
      home.packages = [pkgs.diff-so-fancy pkgs.less];

      programs.git.iniContent = let diffSoFancyCommand = "${pkgs.diff-so-fancy}/bin/diff-so-fancy";
      in {
        core.pager = "${diffSoFancyCommand} | ${pkgs.less}/bin/less --tabs=4 -RFX";
        interfactive.diffFilter = "${diffSoFancyCommand} --patch";
        diff-so-fancy = cfg.diff-so-fancy.options;
      };
    })

  ]);
}
