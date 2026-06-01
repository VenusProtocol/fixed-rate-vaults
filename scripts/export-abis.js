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

// Collect unique implementation contract names across all deployment files.
// Proxy entries (e.g. LiquidationAdapterProxy) strip the "Proxy" suffix since
// the ABI lives on the implementation.
const contractNames = new Set();
for (const file of deploymentFiles) {
  const { addresses } = JSON.parse(fs.readFileSync(file, "utf8"));
  for (const name of Object.keys(addresses)) {
    contractNames.add(name.endsWith("Proxy") ? name.slice(0, -5) : name);
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
