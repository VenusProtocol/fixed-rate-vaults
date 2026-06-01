const fs = require("fs");
const path = require("path");

const NETWORKS = {
  bsc_testnet: 97,
  bsc_mainnet: 56,
  sepolia: 11155111,
  ethereum: 1,
  opbnb_testnet: 5611,
  opbnb_mainnet: 204,
  arbitrum_sepolia: 421614,
  arbitrum_one: 42161,
  op_sepolia: 11155420,
  op_mainnet: 10,
  base_sepolia: 84532,
  base_mainnet: 8453,
  unichain_sepolia: 1301,
  unichain_mainnet: 130,
};

fs.mkdirSync("deployments", { recursive: true });

if (!fs.existsSync("broadcast")) {
  console.log("No broadcast directory found, nothing to export.");
  process.exit(0);
}

const scriptDirs = fs.readdirSync("broadcast");

for (const [network, chainId] of Object.entries(NETWORKS)) {
  const broadcastFiles = scriptDirs
    .map((dir) => path.join("broadcast", dir, String(chainId), "run-latest.json"))
    .filter((f) => fs.existsSync(f));

  if (broadcastFiles.length === 0) continue;

  const transactions = broadcastFiles.flatMap((file) => {
    const { transactions } = JSON.parse(fs.readFileSync(file, "utf8"));
    return transactions.filter((tx) => tx.transactionType === "CREATE");
  });

  const implMap = Object.fromEntries(transactions.map((tx) => [tx.contractAddress.toLowerCase(), tx.contractName]));

  const addresses = {};
  for (const tx of transactions) {
    if (tx.contractName === "TransparentUpgradeableProxy") {
      const implAddress = tx.arguments[0].toLowerCase();
      const implName = implMap[implAddress] ?? "Unknown";
      addresses[`${implName}Proxy`] = tx.contractAddress;
    } else {
      addresses[tx.contractName] = tx.contractAddress;
    }
  }

  const output = { name: network, chainId, addresses };
  fs.writeFileSync(`deployments/${network}_addresses.json`, JSON.stringify(output, null, 2));
  console.log(`Exported ${network} -> deployments/${network}_addresses.json`);
}
