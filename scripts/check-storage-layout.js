/**
 * Fails if an upgradeable contract's storage is no longer a safe upgrade of what is deployed behind
 * its proxy on a mainnet.
 *
 * The comparison itself is OpenZeppelin's `upgrades-core validate`, run on two full builds: today's
 * source, and the source a deployed implementation was built from. forge records the git commit of
 * every broadcast, so that source is the commit in the broadcast that created the implementation. It
 * is rebuilt in a worktree, and the rebuild must produce the code that went on chain.
 *
 * Every implementation deployed behind a proxy is checked against the one before it, and today's
 * source against the newest. That also covers a deploy PR, where the newest implementation is the one
 * being added.
 *
 * A commit's build never changes, so reference builds are kept in cache/storage-layout/<commit>.
 *
 *   yarn check:storage-layout
 */
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

// Testnets redeploy freely, so only mainnet layouts are held to.
const MAINNETS = [1, 10, 56, 130, 204, 8453, 42161];
const PROXY = "TransparentUpgradeableProxy";
const CACHE = path.resolve("cache", "storage-layout");
const OZ = path.resolve("node_modules", ".bin", "openzeppelin-upgrades-core");
// OZ reads the AST and storage layout out of build-info, which a default build does not emit. `--force`
// because a stale build-info left next to a fresh one makes OZ refuse to pick between them.
const BUILD = [
  "build",
  "--force",
  "--skip",
  "test",
  "--skip",
  "script",
  "--build-info",
  "--extra-output",
  "storageLayout",
  "--ast",
];

const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { stdio: "inherit", ...opts });
const hex = (bytes) => bytes.replace(/^0x/, "").toLowerCase();

/** Every mined CREATE in a mainnet broadcast, one per chain and address. */
function mainnetDeployments() {
  const deployments = new Map();
  for (const script of fs.readdirSync("broadcast")) {
    for (const chainId of MAINNETS) {
      const dir = path.join("broadcast", script, String(chainId));
      if (!fs.existsSync(dir)) continue;
      // run-latest.json repeats the newest run-<timestamp>.json.
      for (const file of fs.readdirSync(dir).filter((f) => /^run-\d+\.json$/.test(f))) {
        const broadcast = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
        // Passed to git and used as a cache path, so it has to be a commit hash and nothing else.
        if (!/^[0-9a-f]{7,40}$/.test(broadcast.commit)) {
          throw new Error(`${path.join(dir, file)} records no usable commit: ${broadcast.commit}`);
        }
        const mined = new Set(broadcast.receipts.filter((r) => r.status === "0x1").map((r) => r.transactionHash));
        for (const tx of broadcast.transactions) {
          if (tx.transactionType !== "CREATE" || !mined.has(tx.hash)) continue;
          // Only a transparent proxy is followed to its implementation; any other would go unchecked.
          if (/Proxy$|Beacon/.test(tx.contractName) && tx.contractName !== PROXY) {
            throw new Error(`${tx.contractName} at ${tx.contractAddress} on chain ${chainId} is not supported`);
          }
          const key = `${chainId}:${tx.contractAddress.toLowerCase()}`;
          const known = deployments.get(key);
          if (known && known.commit !== broadcast.commit) {
            throw new Error(`${key} is recorded from both ${known.commit} and ${broadcast.commit}`);
          }
          deployments.set(key, {
            chainId,
            address: tx.contractAddress.toLowerCase(),
            name: tx.contractName,
            proxiedTo: tx.contractName === PROXY ? tx.arguments[0].toLowerCase() : undefined,
            input: hex(tx.transaction.input),
            commit: broadcast.commit,
            timestamp: broadcast.timestamp,
          });
        }
      }
    }
  }
  return [...deployments.values()];
}

/**
 * Each proxied contract with the implementations deployed for it, oldest first. Implementations are
 * matched by contract name, from the proxy's first one on; upgrades after that go through governance
 * and only the new implementation's deployment appears in a broadcast.
 */
function upgradeChains(deployments) {
  const chains = new Map();
  for (const proxy of deployments.filter((d) => d.proxiedTo)) {
    const first = deployments.find((d) => d.chainId === proxy.chainId && d.address === proxy.proxiedTo);
    if (!first) {
      throw new Error(
        `proxy ${proxy.address} on chain ${proxy.chainId} points to ${proxy.proxiedTo}, which no broadcast created`,
      );
    }
    const key = `${first.chainId}:${first.name}`;
    const impls = deployments
      .filter((d) => d.chainId === first.chainId && d.name === first.name && d.timestamp >= first.timestamp)
      .sort((a, b) => a.timestamp - b.timestamp);
    if (!chains.has(key) || chains.get(key)[0].timestamp > impls[0].timestamp) chains.set(key, impls);
  }
  return [...chains.values()];
}

/**
 * Builds `commit` into the cache unless it is there already. OZ names a reference build by its
 * directory, hence `live-<commit>`.
 */
function referenceBuild(commit) {
  const dir = path.join(CACHE, commit);
  const build = { commit, out: path.join(dir, "out"), buildInfo: path.join(dir, `live-${commit}`) };
  if (fs.existsSync(dir)) return build;

  // Built next to the cache and moved in only once complete, so an interrupted build is never reused.
  const partial = `${dir}.partial`;
  fs.rmSync(partial, { recursive: true, force: true });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), `storage-layout-${commit}-`));
  const src = path.join(tmp, "src");
  try {
    run("git", ["worktree", "add", "--detach", src, commit]);
    run("git", ["-C", src, "submodule", "update", "--init", "--recursive"]);
    run(
      "forge",
      [
        ...BUILD,
        "--out",
        path.join(partial, "out"),
        "--build-info-path",
        path.join(partial, `live-${commit}`),
        "--cache-path",
        path.join(partial, "forge-cache"),
      ],
      { cwd: src },
    );
  } finally {
    if (fs.existsSync(src)) run("git", ["worktree", "remove", "--force", src]);
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  fs.renameSync(partial, dir);
  return build;
}

/**
 * Throws unless `build` produces the code `impl` was deployed with. The trailing CBOR metadata is left
 * out: it hashes every source file, comments included, so it can differ where the code does not.
 */
function assertBuiltFrom(impl, build) {
  const artifacts = fs
    .readdirSync(build.out)
    .map((dir) => path.join(build.out, dir, `${impl.name}.json`))
    .filter((f) => fs.existsSync(f));
  if (artifacts.length !== 1)
    throw new Error(`expected one ${impl.name} artifact in ${impl.commit}, found ${artifacts.length}`);

  const built = hex(JSON.parse(fs.readFileSync(artifacts[0], "utf8")).bytecode.object);
  // The last two bytes give the metadata's length, and the metadata itself opens with a CBOR map. Without
  // that, a misread length could strip the whole bytecode and compare nothing.
  const metadataLength = (parseInt(built.slice(-4), 16) + 2) * 2;
  if (metadataLength >= built.length || !/^a[1-7]/.test(built.slice(-metadataLength))) {
    throw new Error(`${impl.name} in ${impl.commit} carries no CBOR metadata to strip`);
  }
  if (impl.input.length < built.length || !impl.input.startsWith(built.slice(0, -metadataLength))) {
    throw new Error(`${impl.name} at ${impl.address} was not built from ${impl.commit}: the rebuilt code differs`);
  }
}

/** Runs OZ's validate on `buildInfo`, comparing `name` against the same contract in `reference`. */
function validateUpgrade(name, buildInfo, reference) {
  run(OZ, [
    "validate",
    buildInfo,
    "--referenceBuildInfoDirs",
    reference.buildInfo,
    "--contract",
    name,
    "--reference",
    `live-${reference.commit}:${name}`,
    "--requireReference",
  ]);
}

const failures = [];
const check = (label, fn) => {
  console.log(`\n=== ${label}`);
  try {
    fn();
  } catch (err) {
    failures.push(label);
    if (!err.status) console.error(err.message); // a failed command has already printed its own output
  }
};

const head = fs.mkdtempSync(path.join(os.tmpdir(), "storage-layout-head-"));
try {
  run("forge", [...BUILD, "--out", path.join(head, "out"), "--cache-path", path.join(head, "cache")]);
  const headBuildInfo = path.join(head, "out", "build-info");

  // Constructors, immutables, selfdestruct, delegatecall and initializers in every upgradeable contract.
  check("upgrade safety", () => run(OZ, ["validate", headBuildInfo]));

  for (const impls of upgradeChains(mainnetDeployments())) {
    const { name, chainId } = impls[0];
    const builds = [];
    check(`${name} on chain ${chainId}: rebuild deployed implementations`, () => {
      for (const impl of impls) {
        const build = referenceBuild(impl.commit);
        assertBuiltFrom(impl, build);
        builds.push(build);
      }
    });
    if (builds.length !== impls.length) continue;

    for (let i = 1; i < impls.length; i++) {
      if (builds[i].commit === builds[i - 1].commit) continue; // same source, nothing to compare
      check(`${name} on chain ${chainId}: ${impls[i - 1].address} -> ${impls[i].address}`, () =>
        validateUpgrade(name, builds[i].buildInfo, builds[i - 1]),
      );
    }
    const live = impls[impls.length - 1];
    check(`${name} on chain ${chainId}: ${live.address} -> working tree`, () =>
      validateUpgrade(name, headBuildInfo, builds[builds.length - 1]),
    );
  }
} finally {
  fs.rmSync(head, { recursive: true, force: true });
}

if (failures.length) {
  console.error(`\nFAILED:\n${failures.map((f) => `  ${f}`).join("\n")}`);
  process.exit(1);
}
console.log("\nAll storage layouts are compatible.");
