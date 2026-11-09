/**
 * Fails if an upgradeable contract's storage is no longer a safe upgrade of what is deployed behind
 * its proxy or beacon on a mainnet.
 *
 * The comparison itself is OpenZeppelin's `upgrades-core validate`, run on two full builds: today's
 * source, and the source a deployed implementation was built from. forge records the git commit of
 * every broadcast, so that source is the commit in the broadcast that created the implementation. It
 * is rebuilt in a worktree, and the rebuild must produce the code that went on chain.
 *
 * Every implementation deployed behind a proxy or beacon is checked against the one before it, and
 * today's source against the newest. That also covers a deploy PR, where the newest implementation is
 * the one being added.
 *
 * A commit's build never changes, so reference builds are kept in cache/storage-layout/<commit>.
 */
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

// Testnets redeploy freely, so only mainnet layouts are held to.
const MAINNETS = [56];
// What each supported proxy's first constructor argument is. A transparent proxy and a beacon hold an
// implementation; a beacon proxy holds a beacon, whose implementation is checked through the beacon.
const POINTS_AT = {
  TransparentUpgradeableProxy: "implementation",
  UpgradeableBeacon: "implementation",
  BeaconProxy: "beacon",
};
const CACHE = path.resolve("cache", "storage-layout");
const OZ = path.resolve("node_modules", ".bin", "openzeppelin-upgrades-core");

// A FOUNDRY_* variable (a profile such as lite, or a single setting) changes the compiled code, so a
// rebuild would stop matching what was deployed. Every build here uses foundry.toml as committed.
for (const key of Object.keys(process.env)) if (key.startsWith("FOUNDRY_")) delete process.env[key];

const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { stdio: "inherit", ...opts });
const hex = (bytes) => bytes.replace(/^0x/, "").toLowerCase();

/**
 * Builds the source folder of the project in `cwd` with what OZ reads: the AST and storage layout in
 * build-info. Tests and deploy scripts are left out so their helpers never reach OZ. `--force` because a
 * stale build-info left next to a fresh one makes OZ refuse to pick between them.
 */
function forgeBuild(cwd, outputs) {
  const { src } = JSON.parse(execFileSync("forge", ["config", "--json"], { cwd, encoding: "utf8" }));
  const flags = ["--force", "--build-info", "--extra-output", "storageLayout", "--ast"];
  run("forge", ["build", src, ...flags, ...outputs], { cwd });
}

/** Every mined CREATE in a mainnet broadcast, one per chain and address. Any other creation but a library throws. */
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
        const libraries = new Set((broadcast.libraries ?? []).map((l) => l.split(":").pop().toLowerCase()));
        for (const tx of broadcast.transactions) {
          if (!mined.has(tx.hash)) continue;
          // forge deploys a linked library by CREATE2. A library holds no storage, so there is nothing to check.
          if (tx.transactionType === "CREATE2" && libraries.has(tx.contractAddress.toLowerCase())) continue;
          // Only a top-level CREATE records what is read here. A CREATE2, or a contract created inside a
          // call, could be a proxy or an implementation that would otherwise drop out without saying so.
          if (tx.transactionType === "CREATE2" || tx.additionalContracts?.length) {
            throw new Error(`${tx.hash} on chain ${chainId} creates a contract other than by a top-level CREATE`);
          }
          if (tx.transactionType !== "CREATE") continue;
          // Any other proxy would leave its implementation unchecked without saying so.
          if (/Proxy$|Beacon/.test(tx.contractName) && !POINTS_AT[tx.contractName]) {
            throw new Error(`${tx.contractName} at ${tx.contractAddress} on chain ${chainId} is not a supported proxy`);
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
            pointsTo: POINTS_AT[tx.contractName] ? tx.arguments[0].toLowerCase() : undefined,
            input: hex(tx.transaction.input),
            libraries: broadcast.libraries ?? [],
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
 * Each contract behind a proxy or beacon with the implementations deployed for it, oldest first.
 * Implementations are matched by contract name, from the first one on; upgrades after that go through
 * governance and only the new implementation's deployment appears in a broadcast.
 */
function upgradeChains(deployments) {
  const target = (d) => deployments.find((t) => t.chainId === d.chainId && t.address === d.pointsTo);
  for (const proxy of deployments.filter((d) => POINTS_AT[d.name] === "beacon")) {
    if (target(proxy)?.name !== "UpgradeableBeacon") {
      throw new Error(`BeaconProxy ${proxy.address} on chain ${proxy.chainId} points to no broadcast's beacon`);
    }
  }

  const chains = new Map();
  for (const proxy of deployments.filter((d) => POINTS_AT[d.name] === "implementation")) {
    const first = target(proxy);
    if (!first) {
      throw new Error(
        `${proxy.name} ${proxy.address} on chain ${proxy.chainId} points to ${proxy.pointsTo}, which no broadcast created`,
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
    forgeBuild(src, [
      "--out",
      path.join(partial, "out"),
      "--build-info-path",
      path.join(partial, `live-${commit}`),
      "--cache-path",
      path.join(partial, "forge-cache"),
    ]);
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

  const { object, linkReferences } = JSON.parse(fs.readFileSync(artifacts[0], "utf8")).bytecode;
  let built = hex(object);
  // A linked library's address is only known at deploy time, so the build leaves a placeholder where the
  // broadcast records the address it linked (`<file>:<library>:<address>`).
  for (const [file, libraries] of Object.entries(linkReferences ?? {})) {
    for (const [library, refs] of Object.entries(libraries)) {
      const linked = impl.libraries.find((l) => l.startsWith(`${file}:${library}:`));
      if (!linked) throw new Error(`${impl.name} links ${library}, which its broadcast records no address for`);
      const address = hex(linked.split(":").pop());
      for (const { start, length } of refs) {
        built = built.slice(0, start * 2) + address + built.slice((start + length) * 2);
      }
    }
  }
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

// Code already deployed can no longer be changed, so an upgrade between two deployed implementations is
// held to OZ's storage rules only. Its other rules apply to today's source, in the upgrade-safety step.
const DEPLOYED = [
  "--unsafeAllow",
  [
    "state-variable-assignment",
    "state-variable-immutable",
    "external-library-linking",
    "struct-definition",
    "enum-definition",
    "constructor",
    "delegatecall",
    "selfdestruct",
    "missing-public-upgradeto",
    "internal-function-storage",
    "missing-initializer",
    "missing-initializer-call",
    "duplicate-initializer-call",
    "incorrect-initializer-order",
  ].join(","),
];

/**
 * Runs OZ's validate on `buildInfo`, comparing `name` against the same contract in `reference`. `extra`
 * is passed through to validate.
 */
function validateUpgrade(name, buildInfo, reference, extra = []) {
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
    ...extra,
  ]);
}

const failures = [];
/** Runs `fn`, recording `label` as failed if it throws. Returns whether it passed. */
const check = (label, fn) => {
  console.log(`\n=== ${label}`);
  try {
    fn();
    return true;
  } catch (err) {
    failures.push(label);
    if (!err.status) console.error(err.message); // a failed command has already printed its own output
    return false;
  }
};

let chains = [];
check("read deployments from broadcasts", () => (chains = upgradeChains(mainnetDeployments())));

const head = fs.mkdtempSync(path.join(os.tmpdir(), "storage-layout-head-"));
const headBuildInfo = path.join(head, "out", "build-info");
try {
  const built = check("build working tree", () =>
    forgeBuild(".", ["--out", path.join(head, "out"), "--cache-path", path.join(head, "cache")]),
  );

  // Constructors, immutables, selfdestruct, delegatecall and initializers in every upgradeable contract.
  if (built) check("upgrade safety", () => run(OZ, ["validate", headBuildInfo]));

  for (const impls of built ? chains : []) {
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
        validateUpgrade(name, builds[i].buildInfo, builds[i - 1], DEPLOYED),
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
