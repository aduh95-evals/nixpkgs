{
  lib,
  stdenv,
  fetchurl,
  testers,
  unzip,
}:

let
  inherit (stdenv.hostPlatform) isStatic isDarwin isWindows;
  libName =
    if isStatic then
      "libperfetto.a"
    else if isWindows then
      "perfetto.dll"
    else
      "libperfetto${stdenv.hostPlatform.extensions.sharedLibrary}";
  privateLibs = if isWindows then "-lws2_32" else "-lpthread";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "perfetto-sdk";
  version = "57.2";

  # The amalgamated SDK sources (a single perfetto.cc / perfetto.h pair) are
  # published as a release artifact, they are not part of the git repository.
  src = fetchurl {
    url = "https://github.com/google/perfetto/releases/download/v${finalAttrs.version}/perfetto-cpp-sdk-src.zip";
    hash = "sha256-xvo9ia7jD32jlALJzReMny40RUT9pcIQn9hFfjGcOi8=";
  };

  nativeBuildInputs = [ unzip ];

  strictDeps = true;
  sourceRoot = ".";

  # The release artifact ships no build system, the amalgamated translation unit
  # has to be compiled by hand.
  buildPhase = ''
    runHook preBuild

    $CXX $CXXFLAGS -std=c++17 -fPIC -O2 -c perfetto.cc -o perfetto.o
    ${
      if isStatic then
        "$AR rcs ${libName} perfetto.o"
      else if isDarwin then
        "$CXX $CXXFLAGS $LDFLAGS -dynamiclib -install_name $out/lib/${libName} -o ${libName} perfetto.o"
      else if isWindows then
        "$CXX $CXXFLAGS $LDFLAGS -shared -Wl,--out-implib,libperfetto.dll.a -o ${libName} perfetto.o ${privateLibs}"
      else
        "$CXX $CXXFLAGS $LDFLAGS -shared -Wl,-soname,${libName} -o ${libName} perfetto.o ${privateLibs}"
    }

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 perfetto.h $out/include/perfetto.h
    ${
      if isStatic then
        "install -Dm644 ${libName} $out/lib/${libName}"
      else if isWindows then
        "install -Dm755 ${libName} $out/bin/${libName}\n"
        + "    install -Dm644 libperfetto.dll.a $out/lib/libperfetto.dll.a"
      else
        "install -Dm755 ${libName} $out/lib/${libName}"
    }

    mkdir -p $out/lib/pkgconfig
    substitute ${./perfetto.pc.in} $out/lib/pkgconfig/perfetto.pc \
      --subst-var out \
      --subst-var-by version ${finalAttrs.version} \
      --subst-var-by libsPrivate ${lib.escapeShellArg privateLibs}

    runHook postInstall
  '';

  passthru.tests.pkg-config = testers.hasPkgConfigModules {
    package = finalAttrs.finalPackage;
  };

  meta = {
    description = "Perfetto tracing SDK, the client library used to emit traces";
    longDescription = ''
      The amalgamated C++ distribution of the Perfetto SDK, i.e. the library an
      application links against to become a Perfetto producer. Tools such as
      `traced` or `trace_processor` are not part of this package.
    '';
    homepage = "https://perfetto.dev/docs/instrumentation/tracing-sdk";
    changelog = "https://github.com/google/perfetto/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [ aduh95 ];
    pkgConfigModules = [ "perfetto" ];
    platforms = lib.platforms.all;
  };
})
