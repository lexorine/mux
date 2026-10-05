{
  description = "Hermetic Nix build of mux (j4niwzis/mux), the GUI, for Cachix";

  nixConfig = {
    extra-substituters = [ "https://mux.cachix.org" ];
    extra-trusted-public-keys = [
      "mux.cachix.org-1:btkZGxY0dksblZlVjSvDwjEF+U6FwLB6d9PW+mbn6SQ="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The dependency family, at the commits mux's own CMakeLists.txt pins.
    chevron = { url = "github:j4niwzis/chevron/bbc3e0d2a2b67f1cd039c582ef131bafa2d81348"; flake = false; };
    knot = { url = "github:j4niwzis/knot/fa98812b7a63dde5d81dcd51f3ee0dceb6f98678"; flake = false; };
    loom = { url = "github:j4niwzis/loom/b893a2c9ed6780484866072d8a375e54ae66b5ad"; flake = false; };
    splice = { url = "github:j4niwzis/splice/c3dc7bcff228014456b6f4b925da01118cb9e6f1"; flake = false; };
    tern = { url = "github:j4niwzis/tern/28a2bfad133e61d072d36bf831a231a3adf503a3"; flake = false; };
    boost-pfr = { url = "github:boostorg/pfr/401385c240027423acbb1eb6dea2abe0043db5aa"; flake = false; };
    skiff = { url = "github:j4niwzis/skiff/45144706381555614a5e5bc52c44bb90d474d24a"; flake = false; };
    skiff-widgets = { url = "github:j4niwzis/skiff-widgets/0cdf560945dad34417600d3cfc50136dddcd7431"; flake = false; };
    # alef: the pin mux's CMakeLists.txt carries.
    alef = { url = "github:j4niwzis/alef/af2097d1ce5571fd22435540d411a774c199968e"; flake = false; };

    # Assets mux #embed s. CMake checks for these before downloading, so
    # pre-creating them keeps configure off the network.
    cldr-en = {
      url = "https://raw.githubusercontent.com/unicode-org/cldr/90e46ed15ee4716196d3299f669eff6259ec1dca/common/annotations/en.xml";
      flake = false;
    };
    cldr-ru = {
      url = "https://raw.githubusercontent.com/unicode-org/cldr/90e46ed15ee4716196d3299f669eff6259ec1dca/common/annotations/ru.xml";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, alef, chevron, knot, loom, splice, tern,
              boost-pfr, skiff, skiff-widgets, cldr-en, cldr-ru, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      # Upstream README: "clang 23 with libc++". Pinned libc++ 21 has no
      # std::views::enumerate (P2164R9, landed for LLVM 23), which splice
      # 4bc0782 uses in src/bytes.cc. So the whole toolchain comes from
      # llvmPackages_23, not the default (21.1.8) stdenv.
      cc = pkgs.llvmPackages_23.clang;
      cxxStdenv = pkgs.llvmPackages_23.libcxxStdenv;
      cxxLib = pkgs.llvmPackages_23.libcxx;

      # cmake-everywhere itself, as a FILE in the store rather than an
      # unpacked directory.
      #
      # get_cme.cmake's own words: "A build with no network cannot download
      # this ... Such a build declares the archive among its own sources --
      # by the same URL and the same digest -- and says where it put it."
      # That is -DCME_ARCHIVE, and it re-checks the digest itself, so this
      # hash is verified twice: once by Nix, once by cme.
      #
      # This replaces an earlier -DCME_SOURCE_DIR, which needed the archive
      # copied and chmod'd into the source tree; that made patchPhase run for
      # minutes and then die with SIGSEGV, on both prtapc and a GitHub
      # runner. Nothing writes to the read-only source tree any more.
      cmeArchive = pkgs.fetchurl {
        url = "https://github.com/j4niwzis/cmake-everywhere/releases/download/v0.2.32/cmake-everywhere-0.2.32.tar.gz";
        # Same digest get_cme.cmake has compiled in for v0.2.32.
        hash = "sha256-ehq0fN6fSx4M/Oe3maULjjvrIXj5jm7sKGR04v+Q+IQ=";
      };

      # cme's documented offline mechanism, in its own words: "A checkout
      # somebody else made, named by whoever knows where it is. This is what
      # a build with no network is given." Each port reads ${PORT}_SOURCE_DIR.
      portSrcs = {
        alef = alef; chevron = chevron; knot = knot; loom = loom;
        splice = splice; tern = tern; boost-pfr = boost-pfr;
        skiff = skiff; skiff-widgets = skiff-widgets;
      };

      # CPM checks CPM_${NAME}_SOURCE before any FetchContent involvement
      # and, when it is set, recurses with SOURCE_DIR only -- dropping
      # GITHUB_REPOSITORY/GIT_TAG, so nothing is left to download. That is
      # the override that works.
      #
      # -D<PORT>_SOURCE_DIR was tried first and does NOT: it feeds a
      # cme_declare_port field that nothing here sets.
      portFlags = lib.concatStringsSep " "
        (lib.mapAttrsToList (n: v: "-DCPM_${n}_SOURCE=${v}") portSrcs);

      # boost-pfr's port name is `boost-pfr` with the hyphen; `boost_pfr` is
      # only the find_package spelling. So: CPM_boost-pfr_SOURCE.
      boostPfrOverride = "-DCPM_boost-pfr_SOURCE=${boost-pfr}";

      # 3. Fortify off: nixpkgs hardening sets _FORTIFY_SOURCE, and glibc's
      #    __fortify_function has internal linkage, which a module cannot
      #    export. The cc-wrapper appends hardening AFTER user flags, so
      #    -U_FORTIFY_SOURCE cannot undo it.
      # 4. -nostdinc++ drops libstdc++ AND every other C++ include dir, so
      #    glibc's C headers (pthread.h, which libc++'s
      #    <__thread/support/pthread.h> needs), boost's and openssl's are
      #    named again by hand.
      # 5. -lc++/-lc++abi must be named at link; -L alone leaves the std
      #    module's symbols unresolved.
      # Every include dir is named explicitly, because -nostdinc++ also
      # suppresses the -isystem entries the nix cc-wrapper would otherwise
      # append from NIX_CFLAGS_COMPILE. That is not a theoretical concern:
      # skiff's failing compile line carried exactly these six and no GL
      # header path at all, so `libglvnd` in nativeBuildInputs bought
      # nothing while -nostdinc++ was in force.
      cxxFlags = lib.concatStringsSep " " [
        "-nostdinc++"
        "-isystem ${cxxLib.dev}/include/c++/v1"
        "-isystem ${cxxLib}/share/libc++/v1"
        "-isystem ${pkgs.glibc.dev}/include"
        "-isystem ${pkgs.boost.dev}/include"
        "-isystem ${pkgs.openssl.dev}/include"
        "-isystem ${pkgs.libglvnd.dev}/include"
        "-isystem ${pkgs.zlib.dev}/include"
        "-isystem ${pkgs.libpng.dev}/include"
        "-isystem ${pkgs.libjpeg_turbo.dev}/include"
        "-isystem ${pkgs.libwebp}/include"
        "-isystem ${pkgs.freetype.dev}/include"
        "-isystem ${pkgs.harfbuzz.dev}/include"
        "-isystem ${pkgs.expat.dev}/include"
        "-isystem ${pkgs.libx11.dev}/include"
        "-isystem ${pkgs.libxext.dev}/include"
        "-isystem ${pkgs.libxkbcommon.dev}/include"
        "-isystem ${pkgs.libxrandr.dev}/include"
        "-isystem ${pkgs.wayland.dev}/include"
        "-isystem ${pkgs.wayland-protocols}/share/wayland-protocols"
        "-isystem ${pkgs.vulkan-headers}/include"
        "-isystem ${pkgs.sdl3.dev}/include"
        "-isystem ${pkgs.ffmpeg.dev}/include"
        # Audio. src/audio.cc includes <opus.h> and <vorbis/vorbisfile.h>.
        # nixpkgs installs opus as opus/opus.h, so the include/opus directory
        # is named too, to make the bare <opus.h> resolve. opusfile ships no
        # headers at all and is not needed here.
        "-isystem ${pkgs.libopus.dev}/include"
        "-isystem ${pkgs.libopus.dev}/include/opus"
        "-isystem ${pkgs.libvorbis.dev}/include"
        "-isystem ${pkgs.libogg.dev}/include"
      ];

      ldFlags = lib.concatStringsSep " " [
        "-L${cxxLib}/lib"
        "-L${pkgs.glibc}/lib"
        "-Wl,-rpath,${cxxLib}/lib"
        "-Wl,-rpath,${pkgs.glibc}/lib"
        "-lc++"
        "-lc++abi"
      ];

      buildInputsList = with pkgs; [
        cc cmake ninja gn pkg-config which git perl python3
        cargo rustc
        boost openssl
        # The GUI stack. SDL3 and FFmpeg are REQUIRED by mux's CMakeLists,
        # and cme feature-probes FFmpeg's components.
        sdl3 ffmpeg libopus libvorbis vulkan-headers expat harfbuzz
        # Skia's own system deps: its third_party/externals is empty in a
        # cme build, so every codec and font library comes from nixpkgs.
        zlib libpng libjpeg_turbo libwebp freetype
        # Skia's GL backend, which skiff includes unconditionally:
        #   src/skia.cc:14:10: fatal error: 'GL/gl.h' file not found
        libglvnd.dev
        # Windowing headers SDL3 opens windows on.
        libx11 libxext libxkbcommon wayland wayland-protocols
      ];

      env = {
        MUX_STDLIB_JSON = "${cxxLib}/lib/libc++.modules.json";
        MUX_CXXFLAGS = cxxFlags;
        MUX_LDFLAGS = ldFlags;
        MUX_CME_ARCHIVE = "${cmeArchive}";
        MUX_PORTS = portFlags;
        MUX_BOOST_PFR = boostPfrOverride;
        MUX_CLDR_EN = "${cldr-en}";
        MUX_CLDR_RU = "${cldr-ru}";
        caCerts = "${pkgs.cacert}";
      };

      # Everything happens in the build directory, which is writable. The
      # source tree is read-only (it comes from a flake input) and is never
      # touched: no chmod -R, no cp into it.
      configPhase = ''
        runHook preConfigure
        export hardeningEnable=$hardeningDisable

        # Skia is still fetched, as a pinned archive whose digest cme checks.
        # Nix's git and curl carry their own CA store and do not trust the
        # runner's, so without this they fail with "unable to get local
        # issuer certificate".
        export NIX_SSL_CERT_FILE="''${caCerts}/etc/ssl/certs/ca-bundle.crt"
        export SSL_CERT_FILE="''${caCerts}/etc/ssl/certs/ca-bundle.crt"

        # vodozemac is a Rust library built by cargo through cmake-everywhere
        # (upstream added E2EE after the fork's pins). Cargo needs a writable
        # home; its git deps are fetched at configure time through the same
        # CA bundle the rest of the build uses. No CARGO_NET_OFFLINE: cme
        # vendored nothing for cargo, the vodozemac checkout comes from
        # FetchContent at configure time, and cargo's own git fetch of
        # matrix-org/vodozemac#0.10.0 needs the network.
        export CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
        mkdir -p "$CARGO_HOME"
        export CARGO_NET_GIT_FETCH_WITH_CLI=true
        export GIT_SSL_CAINFO="''${caCerts}/etc/ssl/certs/ca-bundle.crt"

        # emoji_keywords.cc #embed s these. CMake checks for them before
        # downloading and re-verifies its own sha256 of what it finds.
        mkdir -p build/cldr
        cp "$MUX_CLDR_EN" build/cldr/en.xml
        cp "$MUX_CLDR_RU" build/cldr/ru.xml

        # 1. CMake defaults CXX to `c++`, which in a nix stdenv is gcc, and
        #    gcc rejects `import std`. Both compilers are named explicitly.
        # 2. libc++'s module metadata is not in clang's resource dir, so it
        #    is pointed at explicitly.
        cmake -S . -B build -G Ninja \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_C_COMPILER=clang \
          -DCMAKE_CXX_COMPILER=clang++ \
          -DCMAKE_CXX_STANDARD_LIBRARY=libc++ \
          -DCMAKE_CXX_STDLIB_MODULES_JSON="$MUX_STDLIB_JSON" \
          -DCMAKE_CXX_FLAGS="$MUX_CXXFLAGS" \
          -DCMAKE_EXE_LINKER_FLAGS="$MUX_LDFLAGS" \
          -DCME_ARCHIVE="$MUX_CME_ARCHIVE" \
          $MUX_PORTS \
          $MUX_BOOST_PFR \
          -DMUX_UI=$MUX_UI \
          -DMUX_TESTS=OFF
        runHook postConfigure
      '';

      mkMux = { name, ui, install }: cxxStdenv.mkDerivation {
        inherit name;
        pname = name;
        version = "0.1";

        # .github/ is excluded deliberately. The source is the whole repo,
        # so a workflow-only commit changed the hash and produced a different
        # store path -- which is exactly what a binary cache must not do:
        # three builds of identical sources landed on three paths, and only
        # the last was ever substitutable.
        src = lib.cleanSourceWith {
          src = ./.;
          name = "mux-source";
          filter = path: type:
            let base = baseNameOf (toString path);
            in !(lib.hasPrefix "." base) || base == ".editorconfig";
        };

        nativeBuildInputs = buildInputsList;
        buildInputs = [ cxxLib ];

        hardeningDisable = [ "fortify" ];
        dontDisableStatic = true;
        enableParallelBuilding = true;
        doCheck = false;

        inherit (env) MUX_STDLIB_JSON MUX_CXXFLAGS MUX_LDFLAGS MUX_CME_ARCHIVE
                MUX_PORTS MUX_CLDR_EN MUX_CLDR_RU MUX_BOOST_PFR caCerts;
        MUX_UI = ui;
        inherit install;

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
      cliPkg = mkMux { name = "mux-cli"; ui = "OFF"; install = "build/mux-cli"; };

      # Configure-only probe: resolves the whole dependency graph -- Skia,
      # FFmpeg's codecs, SDL3 -- without spending an hour compiling.
      probePkg = cxxStdenv.mkDerivation {
        pname = "mux-configure";
        version = "0.1";
        # .github/ is excluded deliberately. The source is the whole repo,
        # so a workflow-only commit changed the hash and produced a different
        # store path -- which is exactly what a binary cache must not do:
        # three builds of identical sources landed on three paths, and only
        # the last was ever substitutable.
        src = lib.cleanSourceWith {
          src = ./.;
          name = "mux-source";
          filter = path: type:
            let base = baseNameOf (toString path);
            in !(lib.hasPrefix "." base) || base == ".editorconfig";
        };
        nativeBuildInputs = buildInputsList;
        buildInputs = [ cxxLib ];
        hardeningDisable = [ "fortify" ];
        dontBuild = true;
        inherit (env) MUX_STDLIB_JSON MUX_CXXFLAGS MUX_LDFLAGS MUX_CME_ARCHIVE
                MUX_PORTS MUX_CLDR_EN MUX_CLDR_RU MUX_BOOST_PFR caCerts;
        MUX_UI = "ON";
        configurePhase = configPhase;
        # Copy the configure tree out dereferencing symlinks rather than
        # verbatim: cme leaves absolute symlinks into the build directory
        # (cme-include/.../skia -> $PWD/build/_deps/skia-src/include), and
        # Nix's noBrokenSymlinks check rejects a store output containing
        # one. Resolving them also makes the probe output self-contained.
        installPhase = ''
          runHook preInstall
          mkdir -p $out/tree
          cp -rL build/. $out/tree/
          runHook postInstall
        '';
      };
    in
    {
      packages.${system} = {
        mux = muxPkg;
        mux-cli = cliPkg;
        default = muxPkg;
        mux-configure = probePkg;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${muxPkg}/bin/mux";
        };
        cli = {
          type = "app";
          program = "${cliPkg}/bin/mux-cli";
        };
      };
    };
}