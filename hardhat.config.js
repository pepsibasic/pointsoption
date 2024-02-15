require("@nomiclabs/hardhat-waffle");
require("dotenv").config();

module.exports = {
  solidity: "0.8.20",
  paths: {
    sources: "./contracts",
  },
  networks: {
    // for Sepolia testnet
    "blast-sepolia": {
      url: "https://sepolia.blast.io",
      accounts: [process.env.PRIVATE_KEY],
      gasPrice: 1000000000,
    },
    // for local dev environment
    "blast-local": {
      url: "http://localhost:8545",
      accounts: [process.env.PRIVATE_KEY],W
      gasPrice: 1000000000,
    },
  },
  defaultNetwork: "blast-local",
  scripts: {
    deploy: "scripts/deploy.js",
  },
};
