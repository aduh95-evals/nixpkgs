{
  cmake,
  fetchFromGitHub,
  fetchurl,
  lib,
  nix-update-script,
  pkg-config,
  stdenv,
  testers,
  unzip,
}:

let
  inherit (stdenv.hostPlatform) isStatic isDarwin;
  libName = "libperfetto${if isStatic then ".a" else stdenv.hostPlatform.extensions.sharedLibrary}";

  version = "57.2";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "perfetto-sdk";
  inherit version;

  # The amalgamated SDK sources (a single perfetto.cc / perfetto.h pair) are
  # published as a release artifact, skipping the need for the heavy Google build chain.
  src = fetchurl {
    url = "https://github.com/google/perfetto/releases/download/v${finalAttrs.version}/perfetto-cpp-sdk-src.zip";
    hash = "sha256-xvo9ia7jD32jlALJzReMny40RUT9pcIQn9hFfjGcOi8=";
  };

  nativeBuildInputs = [ unzip ];

  strictDeps = true;
  sourceRoot = ".";

  # The release artifact ships no build system
  buildPhase = ''
    runHook preBuild

    $CXX $CXXFLAGS -std=c++17 -fPIC -O2 -c perfetto.cc -o perfetto.o
    ${
      if isStatic then
        "$AR rcs libperfetto.a perfetto.o"
      else
        "$CXX $CXXFLAGS $LDFLAGS ${
          if isDarwin then "-dynamiclib -install_name $out/lib/" else "-shared -lpthread -Wl,-soname,"
        }${libName} -o ${libName} perfetto.o"
    }

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm${if isStatic then "644" else "755"} ${libName} $out/lib/${libName}
    install -Dm644 perfetto.h $out/include/perfetto.h

    mkdir -p $out/lib/pkgconfig
    cat -> $out/lib/pkgconfig/perfetto.pc << EOF
    prefix=$out
    exec_prefix=\''${prefix}
    libdir=\''${exec_prefix}/lib
    includedir=\''${prefix}/include

    Name: perfetto
    Description: Perfetto tracing SDK (amalgamated C++ distribution)
    Version: ${finalAttrs.version}
    Cflags: -I\''${includedir}
    Libs: -L\''${libdir} -lperfetto
    Libs.private: -lpthread
    EOF

    runHook postInstall
  '';

  passthru = {
    tests = {
      pkg-config = testers.hasPkgConfigModules {
        package = finalAttrs.finalPackage;
      };

      examples =
        let
          src = fetchFromGitHub {
            owner = "google";
            repo = "perfetto";
            tag = "v${version}";
            hash = "sha256-0Syqu43M+XWD15I3qSNaL8Vck6bconRz+6aK4V+0pBA=";
            sparseCheckout = [ "examples/sdk" ];
          };
        in
        (stdenv.mkDerivation {
          pname = "perfetto-sdk-examples";
          inherit version src;

          postPatch = ''
            substituteInPlace CMakeLists.txt --replace-fail "add_library(perfetto STATIC ../../sdk/perfetto.cc)" "
              find_package(PkgConfig REQUIRED)
              pkg_check_modules(PERFETTO REQUIRED IMPORTED_TARGET perfetto)
              add_library(perfetto ALIAS PkgConfig::PERFETTO)
            "
          '';

          sourceRoot = "${src.name}/examples/sdk";

          nativeBuildInputs = [
            cmake
            finalAttrs.finalPackage
            pkg-config
          ];

          # The examples have no install rules. example_system_wide is a long running process, we
          # still build it to ensure it compiles but won't bother trying to run it.
          installPhase = ''
            runHook preInstall

            find . -maxdepth 1 -type f -executable -not -name example_system_wide -exec install -Dt $out/bin {} +

            runHook postInstall
          '';
          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck

            for bin in $out/bin/*; do
              echo "Running $bin"
              "$bin"
            done

            runHook postInstallCheck
          '';
        });
    };

    updateScript = nix-update-script {
      extraArgs = [
        "--subpackage"
        "tests.examples"
      ];
    };
  };

  meta = {
    description = "Perfetto tracing SDK, the client library used to emit traces";
    longDescription = ''
      The amalgamated C++ distribution of the Perfetto SDK, i.e. the library an
      application links against to become a Perfetto producer. Tools such as
      `traced` or `trace_processor` are not part of this package.
    '';
    homepage = "https://perfetto.dev/";
    changelog = "https://github.com/google/perfetto/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [ aduh95 ];
    pkgConfigModules = [ "perfetto" ];
    platforms = lib.platforms.unix;
  };
})
