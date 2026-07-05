{
  description = "Home-ops development environment";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        target =
          if pkgs.stdenv.isLinux then "linux"
          else if pkgs.stdenv.isDarwin then "darwin"
          else throw "Unsupported platform";

        arch =
          if pkgs.stdenv.isAarch64 then "arm64"
          else if pkgs.stdenv.isx86_64 then "amd64"
          else throw "Unsupported architecture";

        talosctlHash = {
          darwin-arm64 = "sha256-Wnc2RTyWUsHhiZ3565BaPmQO3uz8UTueYG5EwsPsBTE=";
          darwin-amd64 = "sha256-XygnK3f8lODzFFBiYzBQUYRs3EZM8zqX/RCQKOKvtUk=";
          linux-arm64 = "sha256-Tbunq8pPwW0CKxOo6zuA0lE4J8/t6xobC1TfSNrWjmY=";
          linux-amd64 = "sha256-EaJ0XPkrAWtHg6z161a/w5Su3mGpdt0Xtej20JOX4io=";
        }."${target}-${arch}";

        # Fetch latest talosctl from GitHub
        talosctl-latest = pkgs.stdenv.mkDerivation rec {
          pname = "talosctl";
          version = "1.12.0";

          src = pkgs.fetchurl {
              url = "https://github.com/siderolabs/talos/releases/download/v${version}/talosctl-${target}-${arch}";
            sha256 = talosctlHash;
          };

          dontUnpack = true;
          dontBuild = true;

          installPhase = ''
            mkdir -p $out/bin
            cp $src $out/bin/talosctl
            chmod +x $out/bin/talosctl
          '';

          meta = with pkgs.lib; {
            description = "CLI for Talos Linux";
            homepage = "https://www.talos.dev/";
            license = licenses.mpl20;
            platforms = platforms.linux ++ platforms.darwin;
          };
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Python
            python312
            makejinja
            # Kubernetes tools
            kubectl
            kubernetes-helm
            helmfile
            kustomize
            kubeconform
            fluxcd
            cilium-cli
            # Talos
            talosctl-latest  # Using latest from GitHub
            talhelper
            # Cloud tools
            cloudflared
            gh
            just
            # Configuration management
            sops
            age
            cue
            gum
            # Build tools
            go-task
            gnumake
            # CLI utilities
            jq
            yq-go
            minijinja
          ];
          shellHook = ''
            # Set environment variables
            export JUST_UNSTABLE=1
            #export KUBECONFIG="$(pwd)/kubeconfig"
            export SOPS_AGE_KEY_FILE="$(pwd)/age.key"
            export TALOSCONFIG="$(pwd)/talosconfig"
            export MINIJINJA_CONFIG_FILE="$(pwd)/.minijinja.toml"
            echo "🚀 Home-ops development environment loaded!"
            echo "📝 KUBECONFIG: $KUBECONFIG"
            echo "🔐 SOPS_AGE_KEY_FILE: $SOPS_AGE_KEY_FILE"
            echo "⚙️  TALOSCONFIG: $TALOSCONFIG"
            echo "📦 talosctl version: $(talosctl version --client --short 2>/dev/null || echo 'unknown')"
          '';
        };
      }
    );
}
