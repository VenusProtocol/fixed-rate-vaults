const fs = require("fs");
const path = require("path");

const deploymentsDir = "deployments";
const abisDir = path.join(deploymentsDir, "abis");

fs.mkdirSync(abisDir, { recursive: true });

const deploymentFiles = fs
  .readdirSync(deploymentsDir)
  .filter((f) => f.endsWith("_addresses.json"))
  .map((f) => path.join(deploymentsDir, f));

if (deploymentFiles.length === 0) {
  console.log("No deployment files found, nothing to export.");
  process.exit(0);
}

const broadcastFiles = fs.existsSync("broadcast") ? fs.readdirSync("broadcast", { recursive: true }) : [];

// Collect unique implementation contract names across all deployment files. ABIs follow deployments, not src/,
// so a contract change alone never updates an ABI before that contract is deployed.
// Proxy entries (e.g. LiquidationAdapterProxy) strip the "Proxy" suffix since
// the ABI lives on the implementation.
const contractNames = new Set();
for (const file of deploymentFiles) {
  const { chainId, addresses } = JSON.parse(fs.readFileSync(file, "utf8"));

  // Custody receipt tokens are recorded under their symbol (see export-deployments.js), which names no artifact,
  // so map each address to the contract this chain's broadcast runs created there.
  const createdAs = {};
  const runs = broadcastFiles.filter(
    (f) => path.basename(path.dirname(f)) === String(chainId) && /^run-.*\.json$/.test(path.basename(f)),
  );
  for (const run of runs) {
    for (const tx of JSON.parse(fs.readFileSync(path.join("broadcast", run), "utf8")).transactions) {
      if (tx.transactionType === "CREATE") createdAs[tx.contractAddress.toLowerCase()] = tx.contractName;
    }
  }

  for (const [name, address] of Object.entries(addresses)) {
    contractNames.add(name.endsWith("Proxy") ? name.slice(0, -5) : (createdAs[address.toLowerCase()] ?? name));
  }
}

for (const name of contractNames) {
  const artifactPath = path.join("out", `${name}.sol`, `${name}.json`);

  if (!fs.existsSync(artifactPath)) {
    console.warn(`Artifact not found for ${name}, skipping. Run forge build first.`);
    continue;
  }

  const { abi } = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  fs.writeFileSync(path.join(abisDir, `${name}.json`), JSON.stringify(abi, null, 2));
  console.log(`Exported ABI: ${name} -> deployments/abis/${name}.json`);
}
