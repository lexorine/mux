{
  description = "Hermetic Nix build of mux (j4niwzis/mux), the GUI, for Cachix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Contains the upstream fix for the clang 23 std::format crash in
    # show_space_bars (3acea405), which is why no local patch is needed.
    mux = {
      url = "github:j4niwzis/mux/d89d2b87f650613d80c2c31d5b789df783565a21";
      flake = false;
    };

    cmake-everywhere = {
      url = "https://github.com/j4niwzis/cmake-everywhere/releases/download/v0.2.24/cmake-everywhere-0.2.24.tar.gz";
      flake = false; # pinned by narHash in flake.lock (Lix rejects sha256=)
    };

    # The dependency family, at the commits mux's own cme-lock.json records.
    alef = { url = "github:j4niwzis/alef/902f701a1277335b228ca7252af9b6bf940468ac"; flake = false; };
    chevron = { url = "github:j4niwzis/chevron/29e716ec45db10407960cbe40294c18a270289c0"; flake = false; };
    knot = { url = "github:j4niwzis/knot/9b482200bb588ac53977c215a41e3c27351a4004"; flake = false; };
    loom = { url = "github:j4niwzis/loom/372ee4dd28e8834d45a0173ed68094d368f958f1"; flake = false; };
    splice = { url = "github:j4niwzis/splice/39bc67a00185f488c989d3c18b98e5995e4dc8dd"; flake = false; };
    tern = { url = "github:j4niwzis/tern/8144cacc26012dc1d349b75f6cf326f083c7a69b"; flake = false; };
    boost-pfr = { url = "github:boostorg/pfr/401385c240027423acbb1eb6dea2abe0043db5aa"; flake = false; };

    # The GUI stack. skiff/skiff-widgets are at the pins mux uses now; the
    # older 2c75c88 is what the failing CI runs were built against.
    skiff = { url = "github:j4niwzis/skiff/4dda84c2f5bde1c1495e2ea4d01b86206cf2c67b"; flake = false; };
    skiff-widgets = { url = "github:j4niwzis/skiff-widgets/99bf5557a3713aa414cd14ee550c5dbb7bc75cf4"; flake = false; };

    cldr-en = {
      url = "https://raw.githubusercontent.com/unicode-org/cldr/90e46ed15ee4716196d3299f669eff6259ec1dca/common/annotations/en.xml";
      flake = false;
    };
    cldr-ru = {
      url = "https://raw.githubusercontent.com/unicode-org/cldr/90e46ed15ee4716196d3299f669eff6259ec1dca/common/annotations/ru.xml";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mux, cmake-everywhere, alef, chevron, knot,
              loom, splice, tern, boost-pfr, skiff, skiff-widgets,
              cldr-en, cldr-ru, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      cme = cmake-everywhere;
      cmeVersion = "v0.2.24";

      # cme's documented offline path: "A checkout somebody else made, named
      # by whoever knows where it is. This is what a build with no network is
      # given." Each port reads ${PORT}_SOURCE_DIR.
      portSrcs = {
        alef = alef; chevron = chevron; knot = knot; loom = loom;
        splice = splice; tern = tern; boost-pfr = boost-pfr;
        skiff = skiff; skiff-widgets = skiff-widgets;
      };

      portFlags = lib.concatStringsSep " "
        (lib.mapAttrsToList (n: v: "-D${n}_SOURCE_DIR=${v}") portSrcs);

      # 3. fortify off: glibc's __fortify_function has internal linkage and a
      #    module cannot export it. The cc-wrapper appends hardening AFTER
      #    user flags, so -U_FORTIFY_SOURCE cannot undo it.
      # 4. -nostdinc++ drops libstdc++ AND every other C++ include dir, so
      #    glibc (pthread.h, which libc++'s <__thread/support/pthread.h>
      #    needs), boost and openssl are named again by hand.
      # 5. -lc++/-lc++abi must be named; -L alone leaves the std module's
      #    symbols unresolved at link.
      cxxFlags = lib.concatStringsSep " " [
        "-nostdinc++"
        "-isystem ${pkgs.libcxx.dev}/include/c++/v1"
        "-isystem ${pkgs.libcxx}/share/libc++/v1"
        "-isystem ${pkgs.glibc.dev}/include"
        "-isystem ${pkgs.boost.dev}/include"
        "-isystem ${pkgs.openssl.dev}/include"
      ];

      ldFlags = lib.concatStringsSep " " [
        "-L${pkgs.libcxx}/lib"
        "-L${pkgs.glibc}/lib"
        "-Wl,-rpath,${pkgs.libcxx}/lib"
        "-Wl,-rpath,${pkgs.glibc}/lib"
        "-lc++"
        "-lc++abi"
      ];

      # Shared by both the real build and the configure-only probe.
      env = {
        MUX_STDLIB_JSON = "${pkgs.libcxx}/lib/libc++.modules.json";
        MUX_CXXFLAGS = cxxFlags;
        MUX_LDFLAGS = ldFlags;
        MUX_CME_SRC = "${cme}";
        MUX_CME_VERSION = cmeVersion;
        MUX_PORTS = portFlags;
        MUX_UI = "ON";
      };

      # Pre-create what CMake would otherwise download at configure time.
      patchPhase = ''
        runHook prePatch
        # The unpacked source tree is read-only (it comes from a flake
        # input), so anything written into it needs this first.
        chmod -R u+w .
        cp -r "$MUX_CME_SRC" cme-unpacked
        chmod -R u+w cme-unpacked
        printf '%s\n' "$MUX_CME_VERSION" > cme-unpacked/.cme-revision
        mkdir -p cldr
        cp ${cldr-en} cldr/en.xml
        cp ${cldr-ru} cldr/ru.xml
        runHook postPatch
      '';

      # 1. CMake defaults CXX to `c++`, which in a nix stdenv is gcc, and gcc
      #    rejects `import std` ("Only `libstdc++` is supported").
      # 2. libc++'s module metadata is not in clang's resource dir.
      configPhase = ''
        runHook preConfigure
        export hardeningEnable=$hardeningDisable
        cmake -S . -B build -G Ninja \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_C_COMPILER=clang \
          -DCMAKE_CXX_COMPILER=clang++ \
          -DCMAKE_CXX_STANDARD_LIBRARY=libc++ \
          -DCMAKE_CXX_STDLIB_MODULES_JSON="$MUX_STDLIB_JSON" \
          -DCMAKE_CXX_FLAGS="$MUX_CXXFLAGS" \
          -DCMAKE_EXE_LINKER_FLAGS="$MUX_LDFLAGS" \
          -DCME_SOURCE_DIR="$PWD/cme-unpacked" \
          $MUX_PORTS \
          -DMUX_UI=$MUX_UI \
          -DMUX_TESTS=OFF
        runHook postConfigure
      '';

      mkMux = { name, ui, install }: pkgs.stdenv.mkDerivation {
        inherit name;
        pname = name;
        version = "0.1-${mux.rev or "unknown"}";

        src = mux;
        # No patches: d89d2b8 already carries the std::format workaround.

        nativeBuildInputs = with pkgs; [
          clang cmake ninja gn pkg-config which git perl python3
          boost openssl
          # GUI side. SDL3 and FFmpeg are REQUIRED by mux's CMakeLists, and
          # cme feature-probes each of FFmpeg's components by linking.
          sdl3 ffmpeg opusfile libvorbis vulkan-headers expat
          # Windowing headers SDL3 opens windows on.
          libx11 libxext libxkbcommon wayland wayland-protocols
        ];

        buildInputs = [ pkgs.libcxx ];

        hardeningDisable = [ "fortify" ];
        dontDisableStatic = true;
        enableParallelBuilding = true;
        doCheck = false;

        inherit (env) MUX_STDLIB_JSON MUX_CXXFLAGS MUX_LDFLAGS
                MUX_CME_SRC MUX_CME_VERSION MUX_PORTS;
        MUX_UI = ui;
        inherit install;

        postPatch = patchPhase;
        configurePhase = configPhase;

        buildPhase = ''
          runHook preBuild
          cmake --build build -- -k 0
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out/bin
          install -Dm755 $install -t $out/bin
          runHook postInstall
        '';

        meta = with lib; {
          description = "mux: one chat client for XMPP and Matrix";
          homepage = "https://github.com/j4niwzis/mux";
          license = licenses.agpl3Plus;
          platforms = platforms.linux;
        };
      };
    in
    let
      muxPkg = mkMux { name = "mux"; ui = "ON"; install = "build/mux"; };
    in
    {
      packages.${system} =
        let
          cliPkg = mkMux { name = "mux-cli"; ui = "OFF"; install = "build/mux-cli"; };

          # Configure-only probe: proves the whole dependency graph
          # resolves -- Skia, FFmpeg's eight codecs, SDL3 -- without
          # spending an hour compiling. `nix build .#mux-configure`.
          probePkg = pkgs.stdenv.mkDerivation {
            pname = "mux-configure";
            version = "0.1";
            src = mux;
            nativeBuildInputs = with pkgs; [
              clang cmake ninja gn pkg-config which git perl python3
              boost openssl sdl3 ffmpeg opusfile libvorbis
              vulkan-headers expat
              libx11 libxext libxkbcommon wayland wayland-protocols
            ];
            buildInputs = [ pkgs.libcxx ];
            hardeningDisable = [ "fortify" ];
            dontBuild = true;
            inherit (env) MUX_STDLIB_JSON MUX_CXXFLAGS MUX_LDFLAGS
                    MUX_CME_SRC MUX_CME_VERSION MUX_PORTS MUX_UI;
            postPatch = patchPhase;
            configurePhase = configPhase;
            installPhase = ''
              runHook preInstall
              cp -r build $out
              runHook postInstall
            '';
          };
        in
        {
          mux = muxPkg;
          mux-cli = cliPkg;
          default = muxPkg;
          mux-configure = probePkg;
        };
    };
}
