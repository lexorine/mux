{
  description = "Hermetic Nix build of mux (j4niwzis/mux), the GUI, for Cachix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Carries upstream's fix for the clang 23 std::format crash in
    # show_space_bars (3acea405), so no local patch is needed.
    # The dependency family, at the commits mux's own cme-lock.json records.
    alef = { url = "github:j4niwzis/alef/6dc139f9590dc0d3ac1cc0e9748e67d7a1485480"; flake = false; };
    chevron = { url = "github:j4niwzis/chevron/3019faec6c81fbd677736811308967672e7b9911"; flake = false; };
    knot = { url = "github:j4niwzis/knot/035e53fdee8875614e350331a914256495b9bb22"; flake = false; };
    loom = { url = "github:j4niwzis/loom/823bded41602b99d1f1eee1b2bb8bb847618672f"; flake = false; };
    splice = { url = "github:j4niwzis/splice/f2c25443061ba5353720eccd0a9438793c2ea053"; flake = false; };
    tern = { url = "github:j4niwzis/tern/de984ff791a937fff637f44a8d32e506cad18dbc"; flake = false; };
    boost-pfr = { url = "github:boostorg/pfr/401385c240027423acbb1eb6dea2abe0043db5aa"; flake = false; };
    skiff = { url = "github:j4niwzis/skiff/0531469ad26b78ff839e9660c9bfc6e9448b8b64"; flake = false; };
    skiff-widgets = { url = "github:j4niwzis/skiff-widgets/99bf5557a3713aa414cd14ee550c5dbb7bc75cf4"; flake = false; };

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
        url = "https://github.com/j4niwzis/cmake-everywhere/releases/download/v0.2.24/cmake-everywhere-0.2.24.tar.gz";
        # Same digest get_cme.cmake has compiled in for v0.2.24.
        hash = "sha256-0FNcXeY9Z4MwU7V5ZEvu86eUKwSCFKBk5PnOPD1/1Mw=";
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
        "-isystem ${pkgs.libcxx.dev}/include/c++/v1"
        "-isystem ${pkgs.libcxx}/share/libc++/v1"
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
        "-L${pkgs.libcxx}/lib"
        "-L${pkgs.glibc}/lib"
        "-Wl,-rpath,${pkgs.libcxx}/lib"
        "-Wl,-rpath,${pkgs.glibc}/lib"
        "-lc++"
        "-lc++abi"
      ];

      buildInputsList = with pkgs; [
        clang cmake ninja gn pkg-config which git perl python3
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
        MUX_STDLIB_JSON = "${pkgs.libcxx}/lib/libc++.modules.json";
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

      mkMux = { name, ui, install }: pkgs.stdenv.mkDerivation {
        inherit name;
        pname = name;
        version = "0.1";

        src = lib.cleanSourceWith { src = ./.; name = "mux-source"; };

        nativeBuildInputs = buildInputsList;
        buildInputs = [ pkgs.libcxx ];

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
      probePkg = pkgs.stdenv.mkDerivation {
        pname = "mux-configure";
        version = "0.1";
        src = lib.cleanSourceWith { src = ./.; name = "mux-source"; };
        nativeBuildInputs = buildInputsList;
        buildInputs = [ pkgs.libcxx ];
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
    };
}