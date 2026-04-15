{
  description = "Upac: Universal Package Manager Build System";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        cargoVendorDir = pkgs.rustPlatform.fetchCargoVendor {
            src = ./upac-cli;
            name = "upac-deps";
            hash = "sha256-UtQlxkKR/zsS2ltB9HoXlOYAx2PdAsgA2QzXgLDfIYs=";
          };

        crossPackageSets = {
          x86_64-gnu = if system == "x86_64-linux"
            then pkgs
            else pkgs.pkgsCross.gnu64;

          x86_64-musl = if system == "x86_64-linux"
            then pkgs.pkgsMusl
            else pkgs.pkgsCross.musl64;

          aarch64-gnu = if system == "aarch64-linux"
            then pkgs
            else pkgs.pkgsCross.aarch64-multiplatform;

          aarch64-musl = if system == "aarch64-linux"
            then pkgs.pkgsMusl
            else pkgs.pkgsCross.aarch64-multiplatform-musl;
        };

        makeUpac = { crossPkgs, cpu ? "native" }:
          crossPkgs.stdenv.mkDerivation {
            pname   = "upac";
            version = "0.1.0";
            src     = ./.;

            nativeBuildInputs = with pkgs; [
              zig_0_13 rustc cargo cargo-zigbuild gnumake pkg-config
            ];

            buildInputs = with crossPkgs; [
              ostree glib libarchive.dev libarchive.lib
            ];

            buildPhase = ''
              mkdir -p .cargo
              cat > .cargo/config.toml <<EOF
              [source.crates-io]
              replace-with = "nix-sources"

              [source.nix-sources]
              directory = "${cargoVendorDir}"
              EOF

              make build \
                MODE=release \
                CPU=${cpu} \
                CARGO_FLAGS="--offline --frozen"
            '';

            installPhase = ''
              mkdir -p $out/bin $out/lib
              cp build/bin/upac   $out/bin/
              cp build/lib/*.so   $out/lib/
            '';
          };

        upac-x86_64       = makeUpac { crossPkgs = crossPackageSets.x86_64-gnu;  };
        upac-x86_64-musl  = makeUpac { crossPkgs = crossPackageSets.x86_64-musl; };
        upac-aarch64      = makeUpac { crossPkgs = crossPackageSets.aarch64-gnu;  };
        upac-aarch64-musl = makeUpac { crossPkgs = crossPackageSets.aarch64-musl; };

        upac-x86_64-v2      = makeUpac { crossPkgs = crossPackageSets.x86_64-gnu;  cpu = "x86_64_v2"; };
        upac-x86_64-v3      = makeUpac { crossPkgs = crossPackageSets.x86_64-gnu;  cpu = "x86_64_v3"; };
        upac-x86_64-v4      = makeUpac { crossPkgs = crossPackageSets.x86_64-gnu;  cpu = "x86_64_v4"; };
        upac-x86_64-musl-v2 = makeUpac { crossPkgs = crossPackageSets.x86_64-musl; cpu = "x86_64_v2"; };
        upac-x86_64-musl-v3 = makeUpac { crossPkgs = crossPackageSets.x86_64-musl; cpu = "x86_64_v3"; };
        upac-x86_64-musl-v4 = makeUpac { crossPkgs = crossPackageSets.x86_64-musl; cpu = "x86_64_v4"; };

      in {
        packages = {
          default = upac-x86_64;

          inherit upac-x86_64 upac-x86_64-musl upac-aarch64 upac-aarch64-musl;

          inherit upac-x86_64-v2 upac-x86_64-v3 upac-x86_64-v4;
          inherit upac-x86_64-musl-v2 upac-x86_64-musl-v3 upac-x86_64-musl-v4;

          container-x86_64 = pkgs.dockerTools.buildImage {
            name         = "upac-x86_64";
            tag          = "latest";
            architecture = "amd64";
            copyToRoot   = [ upac-x86_64-musl ];
            config = {
              Cmd = [ "/bin/upac" ];
              Env = [ "LD_LIBRARY_PATH=/lib" ];
            };
          };

          container-aarch64 = pkgs.dockerTools.buildImage {
            name         = "upac-aarch64";
            tag          = "latest";
            architecture = "arm64";
            copyToRoot   = [ upac-aarch64-musl ];
            config = {
              Cmd = [ "/bin/upac" ];
              Env = [ "LD_LIBRARY_PATH=/lib" ];
            };
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig_0_13 rustc cargo cargo-zigbuild gnumake pkg-config ostree glib libarchive
          ];
        };
      }
    );
}
