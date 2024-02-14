const { ethers } = require("hardhat");

async function main() {
  const PointsOption = await ethers.getContractFactory("PointsOption");
  const pointsOption = await PointsOption.deploy();

  await pointsOption.deployed();

  console.log("PointsOption deployed to:", pointsOption.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
