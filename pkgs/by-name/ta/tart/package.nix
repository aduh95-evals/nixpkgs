{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  # Softnet support ("--net-softnet") is disabled by default as it requires
  # passwordless-sudo when installed through nix. Alternatively users may install
  # softnet through other means with "setuid"-bit enabled.
  # See https://github.com/cirruslabs/softnet#installing
  enableSoftnet ? false,
  softnet,
  nix-update-script,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "tart";
  version = "2.34.0";

  src = fetchurl {
    url = "https://github.com/cirruslabs/tart/releases/download/${finalAttrs.version}/tart.tar.gz";
    hash = "sha256-yfFgn0lFJY7w7id91E3JcA1vBpeJoR5Dvn81sKZLMTU=";
  };
  sourceRoot = ".";

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    # ./tart.app/Contents/MacOS/tart binary is required to be used in order to
    # trick macOS to pick tart.app/Contents/embedded.provision profile for elevated
    # privileges that Tart needs
    mkdir -p $out/bin $out/Applications
    cp -r tart.app $out/Applications/tart.app
    makeWrapper $out/Applications/tart.app/Contents/MacOS/tart $out/bin/tart \
      --prefix PATH : ${lib.makeBinPath (lib.optional enableSoftnet softnet)}
    install -Dm444 LICENSE $out/share/tart/LICENSE

    runHook postInstall
  '';

  # Verify the version without launching the installed binary. As of 2.34.0
  # tart.app is shipped as a sealed, hardened-runtime bundle (it now carries a
  # Contents/_CodeSignature resource seal). Executing such a bundle makes macOS
  # set the `restricted` (SF_RESTRICTED) file flag on the app, which the Nix
  # daemon cannot clear when registering the store path, failing with
  # `clearing flags of path "...": Operation not permitted`. Running the check
  # against the unpacked source keeps the flag off the store output.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    tart.app/Contents/MacOS/tart --version | grep -F "${finalAttrs.version}"

    runHook postInstallCheck
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "macOS and Linux VMs on Apple Silicon to use in CI and other automations";
    homepage = "https://tart.run";
    license = lib.licenses.fairsource09;
    maintainers = with lib.maintainers; [
      emilytrau
      aduh95
    ];
    mainProgram = "tart";
    platforms = lib.platforms.darwin;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
