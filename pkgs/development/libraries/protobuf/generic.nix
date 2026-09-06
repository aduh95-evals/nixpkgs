# The cmake version of this build is meant to enable both cmake and .pc being exported
# this is important because grpc exports a .cmake file which also expects for protobuf
# to have been exported through cmake as well.
{
  lib,
  stdenv,
  abseil-cpp,
  buildPackages,
  cmake,
  fetchFromGitHub,
  fetchpatch,
  gtest,
  zlib,
  version,
  hash,
  versionCheckHook,

  # downstream dependencies
  python3,
  grpc,
  enableShared ? !stdenv.hostPlatform.isStatic,

  testers,
  protobuf,
  ...
}:

let
  # Output name -> CMake target (and pkg-config file) whose libraries it holds.
  # `libutf8_range` also holds `libutf8_validity`, which shares its .pc file.
  libraryOutputs = {
    libprotobuf = "libprotobuf";
    libprotobuf_lite = "libprotobuf-lite";
    libprotoc = "libprotoc";
  }
  // lib.optionalAttrs (lib.versionAtLeast version "22") {
    libutf8_range = "utf8_range";
  }
  // lib.optionalAttrs (lib.versionAtLeast version "27") {
    libupb = "libupb";
  };

  libdirFlag = output: "protobuf_INSTALL_LIBDIR_${libraryOutputs.${output}}";
in

stdenv.mkDerivation (finalAttrs: {
  pname = "protobuf";
  inherit version;
  __structuredAttrs = true;

  outputs = [
    "out"
    "bin"
  ]
  ++ lib.attrNames libraryOutputs;

  src = fetchFromGitHub {
    owner = "protocolbuffers";
    repo = "protobuf";
    tag = "v${version}";
    inherit hash;
  };

  patches =
    lib.optionals (lib.versionOlder version "22") [
      # fix protobuf-targets.cmake installation paths, and allow for CMAKE_INSTALL_LIBDIR to be absolute
      # https://github.com/protocolbuffers/protobuf/pull/10090
      (fetchpatch {
        url = "https://github.com/protocolbuffers/protobuf/commit/a7324f88e92bc16b57f3683403b6c993bf68070b.patch";
        hash = "sha256-SmwaUjOjjZulg/wgNmR/F5b8rhYA2wkKAjHIOxjcQdQ=";
      })
    ]
    ++ lib.optionals (lib.versions.major version == "29") [
      # fix temporary directory handling to avoid test failures on darwin
      # https://github.com/NixOS/nixpkgs/issues/464439
      (fetchpatch {
        url = "https://github.com/protocolbuffers/protobuf/commit/0e9d0f6e77280b7a597ebe8361156d6bb1971dca.patch";
        hash = "sha256-rIP+Ft/SWVwh9Oy8y8GSUBgP6CtLCLvGmr6nOqmyHhY=";
      })
    ]
    ++ lib.optionals ((lib.versionAtLeast version "30") && (lib.versionOlder version "35")) [
      # workaround nvcc bug in message_lite.h
      # https://github.com/protocolbuffers/protobuf/issues/21542
      # Caused by: https://github.com/protocolbuffers/protobuf/commit/8f7aab29b21afb89ea0d6e2efeafd17ca71486a9
      #
      # A specific consequence of this bug is a test failure when building onnxruntime with cudaSupport
      # See https://github.com/NixOS/nixpkgs/pull/450587#discussion_r2698215974
      (fetchpatch {
        url = "https://github.com/protocolbuffers/protobuf/commit/211f52431b9ec30d4d4a1c76aafd64bd78d93c43.patch";
        hash = "sha256-2/vc4anc+kH7otfLHfBtW8dRowPyObiXZn0+HtQktak=";
      })
    ]
    ++ lib.optionals ((lib.versionAtLeast version "33") && (lib.versionOlder version "35")) [
      # Fix protoc plugins crashing on big-endian platforms
      # https://github.com/protocolbuffers/protobuf/pull/25363
      (fetchpatch {
        url = "https://github.com/protocolbuffers/protobuf/commit/8282f0f8ecf8b847e5964a308e041ba3b049811c.patch";
        hash = "sha256-4c/yLuAd29Cxrz6I9F2Lj02lW2bazIcGb+86uxZY7qA=";
      })
      # Fix packed enum decoding on big-endian platforms
      # https://github.com/protocolbuffers/protobuf/pull/25683
      ./fix-upb-packed-enum-be.patch
    ]
    ++ lib.optionals (lib.versionAtLeast version "34") [
      # upb linker-array fix for newer toolchains (notably GCC 15):
      # `UPB_linkarr_internal_empty_upb_AllExts` can conflict with extension
      # entries in `linkarr_upb_AllExts` during test builds.
      # Context: https://github.com/protocolbuffers/protobuf/issues/21021
      ./fix-upb-linkarr-sentinel-init.patch
    ];

  postPatch =
    lib.optionalString (stdenv.hostPlatform.isDarwin && lib.versionOlder version "29") ''
      substituteInPlace src/google/protobuf/testing/googletest.cc \
        --replace-fail 'tmpnam(b)' '"'$TMPDIR'/foo"'
    ''
    # Adapt https://github.com/protocolbuffers/protobuf/pull/22412 for various
    # older versions. sed -z spans newlines, so this can capture and replace
    # the full multiline #if macro.
    + lib.optionalString (lib.versionOlder version "32") ''
      sed -zi 's/\(#if \w*(clang::musttail)\)[^\n]*\(\\\n[^\n]*\)*/'\
      '\1 \&\& (defined(__aarch64__) || defined(__x86_64__) || defined(_M_X64))/' \
        src/google/protobuf/port_def.inc
    ''
    # Keep the sentinel macro non-retained for GCC 15+ to match generated
    # extension objects in linker arrays and avoid section type conflicts.
    + lib.optionalString (lib.versionAtLeast version "34") ''
      substituteInPlace upb/port/def.inc \
        --replace-fail \
          '#define UPB_LINKARR_SENTINEL UPB_RETAIN __attribute__((weak, used))' \
          '#define UPB_LINKARR_SENTINEL            __attribute__((weak, used))'
    ''
    # Fix gcc15 build failures due to missing <cstring>
    + lib.optionalString ((lib.versions.major version) == "25") ''
      sed -i '1i #include <cstring>' third_party/utf8_range/utf8_validity.cc
    ''
    # Install each library into its own output (see `libraryOutputs`), so the
    # exported CMake targets point at the right place from the start.
    + ''
      substituteInPlace cmake/install.cmake \
        --replace-fail 'DESTINATION ''${CMAKE_INSTALL_LIBDIR} COMPONENT ''${_library}' \
          'DESTINATION ''${protobuf_INSTALL_LIBDIR_''${_library}} COMPONENT ''${_library}'
      sed -i '/install(TARGETS ''${_library} EXPORT protobuf-targets/i \
        set_property(TARGET ''${_library} PROPERTY INSTALL_NAME_DIR "''${protobuf_INSTALL_LIBDIR_''${_library}}")' \
        cmake/install.cmake
      # upb.pc only exists from 29 on
      for pc in protobuf protobuf-lite ${lib.optionalString (lib.versionAtLeast version "29") "upb"}; do
        substituteInPlace cmake/$pc.pc.cmake \
          --replace-fail 'libdir=@CMAKE_INSTALL_FULL_LIBDIR@' "libdir=@protobuf_INSTALL_LIBDIR_lib$pc@"
      done
    ''
    + lib.optionalString (libraryOutputs ? libutf8_range) ''
      sed -i \
        -e '/DESTINATION [$]{CMAKE_INSTALL_LIBDIR}$/s|[$]{CMAKE_INSTALL_LIBDIR}|''${protobuf_INSTALL_LIBDIR_utf8_range}|' \
        -e '/install(TARGETS utf8_validity utf8_range/i \
        set_property(TARGET utf8_validity utf8_range PROPERTY INSTALL_NAME_DIR "''${protobuf_INSTALL_LIBDIR_utf8_range}")' \
        third_party/utf8_range/CMakeLists.txt
      substituteInPlace third_party/utf8_range/cmake/utf8_range.pc.cmake \
        --replace-fail 'libdir=@CMAKE_INSTALL_FULL_LIBDIR@' 'libdir=@protobuf_INSTALL_LIBDIR_utf8_range@'
    '';

  preHook = ''
    export build_protobuf=${
      if (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) then
        lib.getBin buildPackages."protobuf_${lib.versions.major version}"
      else
        (placeholder "bin")
    };
  '';

  # hook to provide the path to protoc executable, used at build time
  setupHook = ./setup-hook.sh;

  nativeBuildInputs = [
    cmake
  ];

  buildInputs = [
    gtest
    zlib
  ];

  propagatedBuildInputs = [
    abseil-cpp
  ];

  strictDeps = true;

  separateDebugInfo = true;

  cmakeDir = if lib.versionOlder version "22" then "../cmake" else null;
  cmakeFlags = [
    (lib.cmakeBool "protobuf_USE_EXTERNAL_GTEST" true)
    (lib.cmakeFeature "protobuf_ABSL_PROVIDER" "package")
    (lib.cmakeBool "protobuf_BUILD_TESTS" finalAttrs.finalPackage.doCheck)
  ]
  ++ lib.optionals enableShared [
    (lib.cmakeBool "protobuf_BUILD_SHARED_LIBS" true)
  ]
  ++ [
    # Upstream sets INSTALL_RPATH relative to CMAKE_INSTALL_LIBDIR, which
    # would point back at `$out`; the rpaths are set through NIX_LDFLAGS below.
    (lib.cmakeBool "CMAKE_SKIP_INSTALL_RPATH" true)
  ]
  ++ lib.mapAttrsToList (
    output: _: lib.cmakeFeature (libdirFlag output) "${placeholder output}/lib"
  ) libraryOutputs;

  # Nothing is installed in `$out/lib` besides symlinks, so don't let the
  # linker wrapper add an rpath to it: `out` refers to every other output and
  # the reverse reference would form a cycle. Point at the real library
  # outputs instead; unused entries are removed by the shrink-rpath fixup.
  env = {
    NIX_NO_SELF_RPATH = "1";
  }
  // lib.optionalAttrs (lib.versions.major version == "29") {
    GTEST_DEATH_TEST_STYLE = "threadsafe";
  };
  preConfigure = ''
    for output in ${lib.concatStringsSep " " (lib.attrNames libraryOutputs)}; do
      export NIX_LDFLAGS+=" -rpath ''${!output}/lib"
    done
  '';

  # Keep `$out/{bin,lib}` populated with symlinks for backwards compatibility.
  postInstall = ''
    ln -s "$bin/bin" "$out/bin"
    for output in ${lib.concatStringsSep " " (lib.attrNames libraryOutputs)}; do
      ln -s "''${!output}"/lib/* "$out/lib/"
    done
  '';

  doCheck =
    # Tests fail to build on 32-bit platforms; fixed in 22.x
    # https://github.com/protocolbuffers/protobuf/issues/10418
    # Also AnyTest.TestPackFromSerializationExceedsSizeLimit fails on 32-bit platforms
    # https://github.com/protocolbuffers/protobuf/issues/8460
    !stdenv.hostPlatform.is32bit;

  nativeInstallCheckInputs = [
    versionCheckHook
  ];
  doInstallCheck = true;

  passthru = {
    tests = {
      pythonProtobuf = python3.pkgs.protobuf;
      inherit grpc;
      inherit (python3.pkgs) celery;

      version = testers.testVersion { package = protobuf; };
    };

    inherit abseil-cpp;
  };

  meta = {
    description = "Google's data interchange format";
    longDescription = ''
      Protocol Buffers are a way of encoding structured data in an efficient
      yet extensible format. Google uses Protocol Buffers for almost all of
      its internal RPC protocols and file formats.
    '';
    license = lib.licenses.bsd3;
    platforms = lib.platforms.all;
    homepage = "https://protobuf.dev/";
    maintainers = with lib.maintainers; [ GaetanLepage ];
    mainProgram = "protoc";
  };
})
