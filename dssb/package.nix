{ lib
, buildNpmPackage
, makeWrapper
, nodejs_22
}:

buildNpmPackage {
  pname = "dsh";
  version = "0.1.1-rc.2";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
    ];
  };
  nodejs = nodejs_22;
  npmDepsHash = "sha256-O6xi+Tf8EDU4MIR3UfMBHOPo91XHTxhPGUb8WlsKg7U=";
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postConfigure = ''
    node --input-type=module <<'NODE'
    import * as nodePty from "node-pty";

    const childMarker = "DSSB_NODE_PTY_CHILD_OK";
    const child = nodePty.spawn(process.execPath, [
      "--eval",
      `process.stdout.write("''${childMarker}\\n")`,
    ], {
      name: "xterm-color",
      cols: 80,
      rows: 24,
      cwd: process.cwd(),
      env: process.env,
    });

    let output = "";
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        try {
          child.kill();
        } catch {
          // The child may have exited as the timeout fires.
        }
        reject(new Error("node-pty smoke timed out"));
      }, 10_000);

      child.onData((data) => {
        output += data;
      });
      child.onExit(({ exitCode, signal }) => {
        clearTimeout(timeout);
        if (exitCode !== 0) {
          reject(new Error(`node-pty child exited ''${exitCode} (signal ''${signal})`));
          return;
        }
        resolve();
      });
    });

    if (!output.includes(childMarker)) {
      throw new Error("node-pty smoke child did not emit its marker");
    }
    process.stdout.write("DSSB_NODE_PTY_NATIVE_OK\n");
    NODE
    printf '%s\n' 'DSSB_NODE_PTY_NATIVE_OK' > .dssb-node-pty-native-smoke
  '';

  installPhase = ''
    runHook preInstall
    install -d -m 0755 "$out/lib/node_modules" "$out/bin" "$out/nix-support"
    test "$(cat .dssb-node-pty-native-smoke)" = "DSSB_NODE_PTY_NATIVE_OK"
    cp -R node_modules/. "$out/lib/node_modules/"
    makeWrapper ${nodejs_22}/bin/node "$out/bin/dsh" \
      --add-flags "$out/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
    install -Dm0644 .dssb-node-pty-native-smoke \
      "$out/nix-support/dssb-node-pty-native-smoke"
    runHook postInstall
  '';

  meta = with lib; {
    description = "DeepSeek DSH command-line interface";
    homepage = "https://www.npmjs.com/package/@deepseek-ai/dsh";
    license = licenses.mit;
    mainProgram = "dsh";
    platforms = platforms.linux;
  };
}
