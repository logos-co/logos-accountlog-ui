{
  description = "logos-accountlog-ui: hold an account's key, write its log, publish it.";

  inputs = {
    # The only input. This app depends on no Logos module: everything it knows
    # about an account is in the Rust library below, linked into the plugin.
    logos-module-builder.url = "github:logos-co/logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    let
      common = logos-module-builder.lib.common;
      lib = logos-module-builder.inputs.nixpkgs.lib;

      # The archive is linked into the plugin, so it has to reach every target
      # the plugin does. x86_64-windows is the builder's cross pseudo-system,
      # and common.mkPkgs is what routes it to logos-nix's mingw package set --
      # nixpkgs.legacyPackages has no such attribute.
      targets = common.systems ++ [ "x86_64-windows" ];

      # The account write path.
      #
      # It is built HERE rather than in a repository of its own, and handed to
      # externalLibInputs as a package rather than as a flake input, because
      # that entry is resolved as `input.packages.<system>.<name>` and nothing
      # requires the thing holding those packages to be a flake. Two things
      # follow, both of them the reason for doing it this way: the archive is
      # built against logos-module-builder's own nixpkgs by construction, which
      # is what a separate library flake needs a `follows` to achieve; and the
      # library and the plugin that links it are versioned by one commit.
      accountCore = system:
        let pkgs = common.mkPkgs system;
        in pkgs.rustPlatform.buildRustPackage {
          pname = "logos-account-core";
          version = "0.1.0";

          # Never copy a local `target/` into the store: it is hundreds of MB of
          # build cache, and nix path: sources do not honour .gitignore.
          src = pkgs.lib.cleanSourceWith {
            src = ./rust-core;
            filter = path: _type: baseNameOf path != "target";
          };

          cargoLock = {
            lockFile = ./rust-core/Cargo.lock;
            # The account crates are a git dependency on an unmerged branch of
            # logos-chat, which has no hash in the lock file. Swap this for
            # `outputHashes` once they are published or merged to main.
            allowBuiltinFetchGit = true;
          };

          # The vault, the staging rules and the C ABI, all of which are correct
          # or not without a runtime to host them. Under cross the test binary
          # is a PE the Linux builder cannot run.
          doCheck = pkgs.stdenv.hostPlatform == pkgs.stdenv.buildPlatform;

          # A staticlib crate installs nothing by default. Ship the archive and
          # the header in the lib/+include/ layout LogosModule.cmake resolves.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib $out/include
            find target -name 'liblogos_account_core.a' -exec cp {} $out/lib/ \;
            cp ${./include/account_core.h} $out/include/account_core.h
            test -f $out/lib/liblogos_account_core.a
            runHook postInstall
          '';
        };
      base = logos-module-builder.lib.mkLogosQmlModule {
        src = ./.;
        configFile = ./metadata.json;
        flakeInputs = inputs;

        externalLibInputs = {
          logos_account_core = {
            input = {
              packages = lib.genAttrs targets (system: {
                logos_account_core = accountCore system;
              });
            };
            packages.default = "logos_account_core";
          };
        };
      };

      # `nix run .#walkthrough`: write a whole account log headless -- make a
      # key, name the account, endorse an installation, publish -- and hold the
      # finished window open. It captures the numbered screenshots in
      # doctests/images on the way through, and the doc-test launches it to
      # capture one shot of the published log (see doctests/accountlog-ui.test.yaml).
      # APP_BIN is this flake's standalone runner; the driver scripts are
      # bundled from ./doctests/walkthrough.
      walkthroughRunner = system:
        let pkgs = import logos-module-builder.inputs.nixpkgs { inherit system; };
        in pkgs.writeShellApplication {
          name = "accountlog-ui-walkthrough";
          runtimeInputs = with pkgs; [ nodejs coreutils util-linux procps bash ];
          text = ''
            export APP_BIN="${base.apps.${system}.default.program}"
            exec bash ${./doctests/walkthrough}/run-walkthrough-show.sh "$@"
          '';
        };

      # x86_64-windows is the builder's cross pseudo-system: nixpkgs has no such
      # package set, and there is nothing here to run a headless walkthrough on,
      # so it gets the base outputs unchanged.
      runnable = system: lib.hasSuffix "-linux" system || lib.hasSuffix "-darwin" system;

      withWalkthrough = attr: entry: builtins.mapAttrs
        (system: outputs:
          if runnable system then outputs // { walkthrough = entry system; } else outputs)
        attr;
    in
    base // {
      apps = withWalkthrough base.apps
        (system: { type = "app"; program = "${walkthroughRunner system}/bin/accountlog-ui-walkthrough"; });
      # Also a package so `nix build .#walkthrough` resolves: the doc-test runner
      # pre-builds its launch target that way to warm the store before the run.
      packages = withWalkthrough base.packages walkthroughRunner;
    };
}
