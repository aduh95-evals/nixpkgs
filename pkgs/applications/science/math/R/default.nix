{
  lib,
  stdenv,
  fetchurl,
  bzip2,
  gfortran,
  libx11,
  libxmu,
  libxt,
  libjpeg,
  libpng,
  libtiff,
  ncurses,
  pango,
  pcre2,
  perl,
  readline,
  tcl,
  texliveSmall,
  tk,
  xz,
  zlib,
  less,
  texinfo,
  graphviz,
  icu,
  pkg-config,
  bison,
  which,
  removeReferencesTo,
  llvmPackages,
  jdk,
  blas,
  lapack,
  curl,
  tzdata,
  withRecommendedPackages ? true,
  enableStrictBarrier ? false,
  enableMemoryProfiling ? false,
  # R as of writing does not support outputting both .so and .a files; it outputs:
  #     --enable-R-static-lib conflicts with --enable-R-shlib and will be ignored
  static ? false,
  testers,
}:

assert (!blas.isILP64) && (!lapack.isILP64);

stdenv.mkDerivation (finalAttrs: {
  pname = "R";
  version = "4.6.0";

  src =
    let
      inherit (finalAttrs) pname version;
    in
    fetchurl {
      url = "https://cran.r-project.org/src/base/R-${lib.versions.major version}/${pname}-${version}.tar.gz";
      hash = "sha256-uNybRUNmDHtZa4eTjfUyOUNQNgl2Un00QijuDtEuRew=";
    };

  outputs = [
    "out"
    "man"
    "tex"
  ];

  nativeBuildInputs = [
    bison
    perl
    pkg-config
    tzdata
    which
    removeReferencesTo
  ]
  # TODO: Remove once #536365 reaches this branch
  ++ lib.optional stdenv.hostPlatform.isDarwin llvmPackages.lld;

  buildInputs = [
    bzip2
    gfortran
    libx11
    libxmu
    libxt
    libxt
    libjpeg
    libpng
    libtiff
    ncurses
    pango
    pcre2
    readline
    (texliveSmall.withPackages (
      ps: with ps; [
        inconsolata
        helvetic
        ps.texinfo
        fancyvrb
        cm-super
        rsfs
      ]
    ))
    xz
    zlib
    less
    texinfo
    graphviz
    icu
    which
    blas
    lapack
    curl
    tcl
    tk
    jdk
  ];
  strictDeps = true;

  patches = [
    ./no-usr-local-search-paths.patch
  ];

  # Test of the examples for package 'tcltk' fails in Darwin sandbox. See:
  # https://github.com/NixOS/nixpkgs/issues/146131
  postPatch = lib.optionalString stdenv.hostPlatform.isDarwin ''
    substituteInPlace configure \
      --replace "-install_name libRblas.dylib" "-install_name $out/lib/R/lib/libRblas.dylib" \
      --replace "-install_name libRlapack.dylib" "-install_name $out/lib/R/lib/libRlapack.dylib" \
      --replace "-install_name libR.dylib" "-install_name $out/lib/R/lib/libR.dylib"
    substituteInPlace tests/Examples/Makefile.in \
      --replace "test-Examples: test-Examples-Base" "test-Examples:" # do not test the examples
  '';

  dontDisableStatic = static;

  env = lib.optionalAttrs stdenv.hostPlatform.isDarwin {
    # TODO: Remove once #536365 reaches this branch
    NIX_CFLAGS_LINK = "-fuse-ld=lld";
  };

  preConfigure = ''
    configureFlagsArray=(
      --disable-lto
      --with${lib.optionalString (!withRecommendedPackages) "out"}-recommended-packages
      --with-blas="-L${blas}/lib -lblas"
      --with-lapack="-L${lapack}/lib -llapack"
      --with-readline
      --with-tcltk --with-tcl-config="${tcl}/lib/tclConfig.sh" --with-tk-config="${tk}/lib/tkConfig.sh"
      --with-cairo
      --with-libpng
      --with-jpeglib
      --with-libtiff
      --with-ICU
      ${lib.optionalString enableStrictBarrier "--enable-strict-barrier"}
      ${lib.optionalString enableMemoryProfiling "--enable-memory-profiling"}
      ${if static then "--enable-R-static-lib" else "--enable-R-shlib"}
      AR=$(type -p ar)
      AWK=$(type -p gawk)
      CC=$(type -p cc)
      CXX=$(type -p c++)
      FC="${gfortran}/bin/gfortran" F77="${gfortran}/bin/gfortran"
      JAVA_HOME="${jdk}"
      RANLIB=$(type -p ranlib)
      CURL_CONFIG="${lib.getExe' (lib.getDev curl) "curl-config"}"
      r_cv_have_curl728=yes
      R_SHELL="${stdenv.shell}"
  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    --disable-R-framework
    --without-x
    --without-static-cairo
    OBJC="clang"
    CPPFLAGS="-isystem ${lib.getInclude stdenv.cc.libcxx}/include/c++/v1"
    LDFLAGS="-L${lib.getLib stdenv.cc.libcxx}/lib"
  ''
  + ''
    )
    echo >>etc/Renviron.in "TCLLIBPATH=${tk}/lib"
    echo >>etc/Renviron.in "TZDIR=${tzdata}/share/zoneinfo"
  '';

  installTargets = [
    "install"
    "install-info"
    "install-pdf"
  ];

  # move tex files to $tex for use with texlive.combine
  # add link in $out since ${R_SHARE_DIR}/texmf is hardcoded in several places
  postInstall = ''
    mv -T "$out/lib/R/share/texmf" "$tex"
    ln -s "$tex" "$out/lib/R/share/texmf"
  '';

  # The store path to "which" is baked into src/library/base/R/unix/system.unix.R,
  # but Nix cannot detect it as a run-time dependency because the installed file
  # is compiled and compressed, which hides the store path.
  postFixup = ''
    echo ${which} > $out/nix-support/undetected-runtime-dependencies
    ${lib.optionalString stdenv.hostPlatform.isLinux ''find $out -name "*.so" -exec patchelf {} --add-rpath $out/lib/R/lib \;''}
  ''
  # Keep the C/C++ compiler out of R's runtime closure (enforced by
  # outputChecks.disallowedReferences below). R records the absolute path of the
  # compiler it was built with in Makeconf (and a couple of launchers); rewrite
  # those to bare command names so packages are compiled with the toolchain
  # provided by their own build environment. Only the compiler's runtime
  # libraries (…-lib) are needed at run time, so repoint the recorded library
  # search paths, and strip any residual paths recorded in compiled objects
  # (e.g. debug/.comment sections).
  + ''
    compilers='cc|gcc|g\+\+|c\+\+|cpp|clang|clang\+\+|gccgo|gfortran|g77|ld|ld\.gold|ld\.bfd|ld\.lld|ar|ranlib|nm|as|strip|dsymutil|install_name_tool|libtool|lipo|otool'
    for f in \
      $out/lib/R/etc/Makeconf $out/lib/R/etc/Renviron \
      $out/lib/R/bin/R $out/bin/R \
      $out/lib/R/bin/libtool $out/lib/R/bin/javareconf \
    ; do
      [ -f "$f" ] && sed -i -E "s#/nix/store/[a-z0-9]{32}-[^/ \"')]*/bin/($compilers)#\1#g" "$f"
    done

    substituteInPlace \
        $out/lib/R/etc/Makeconf \
        ${lib.optionalString (!stdenv.hostPlatform.isDarwin) "$out/lib/R/etc/ldpaths"} \
      --replace-fail "${gfortran.cc}"   "${lib.getLib gfortran.cc}"

    ${lib.optionalString (!stdenv.hostPlatform.isDarwin) ''
      # ldtools is only emitted on some platforms (e.g. x86_64-linux).
      if [ -f $out/lib/R/etc/ldtools ]; then
        substituteInPlace $out/lib/R/etc/ldtools \
          --replace-fail "${gfortran.cc}" "${lib.getLib gfortran.cc}"
      fi

      substituteInPlace $out/lib/R/bin/libtool \
            --replace-fail "${stdenv.cc.cc}" "${lib.getLib stdenv.cc.cc}"''}

    # Neutralise any residual references that are not a plain /bin/<tool> path,
    # e.g. the compiler resource dir baked into libtool's library search path.
    for f in $out/lib/R/etc/Makeconf $out/lib/R/bin/libtool; do
      [ -f "$f" ] && remove-references-to -t ${stdenv.cc} "$f"
    done

    find $out -type f \( -name '*.so' -o -name '*.dylib' \) -exec \
      remove-references-to -t ${stdenv.cc} -t ${stdenv.cc.cc} {} +
  '';

  # Enforce that the compiler wrapper and the unwrapped compiler do not end up in
  # R's runtime closure. On Linux the postFixup above scrubs the references that
  # would otherwise pull them in.
  __structuredAttrs = true;
  outputChecks.out.disallowedReferences = [
    stdenv.cc
    stdenv.cc.cc
  ];

  doCheck = true;
  preCheck = "export HOME=$TMPDIR; export TZ=CET; bin/Rscript -e 'sessionInfo()'";

  enableParallelBuilding = true;

  setupHook = ./setup-hook.sh;

  passthru.tests.pkg-config = testers.testMetaPkgConfig finalAttrs.finalPackage;

  # dependencies (based on \RequirePackage in jss.cls, Rd.sty, Sweave.sty)
  passthru.tlDeps = ps: [
    ps.amsfonts
    ps.amsmath
    ps.fancyvrb
    ps.graphics
    ps.hyperref
    ps.iftex
    ps.jknapltx
    ps.latex
    ps.lm
    ps.tools
    ps.upquote
    ps.url
  ];

  meta = {
    homepage = "http://www.r-project.org/";
    description = "Free software environment for statistical computing and graphics";
    mainProgram = "R";
    license = lib.licenses.gpl2Plus;

    longDescription = ''
      GNU R is a language and environment for statistical computing and
      graphics that provides a wide variety of statistical (linear and
      nonlinear modelling, classical statistical tests, time-series
      analysis, classification, clustering, ...) and graphical
      techniques, and is highly extensible. One of R's strengths is the
      ease with which well-designed publication-quality plots can be
      produced, including mathematical symbols and formulae where
      needed. R is an integrated suite of software facilities for data
      manipulation, calculation and graphical display. It includes an
      effective data handling and storage facility, a suite of operators
      for calculations on arrays, in particular matrices, a large,
      coherent, integrated collection of intermediate tools for data
      analysis, graphical facilities for data analysis and display
      either on-screen or on hardcopy, and a well-developed, simple and
      effective programming language which includes conditionals, loops,
      user-defined recursive functions and input and output facilities.
    '';

    pkgConfigModules = [ "libR" ];
    platforms = lib.platforms.all;

    maintainers = with lib.maintainers; [ jbedo ];
    teams = [ lib.teams.sage ];
  };
})
