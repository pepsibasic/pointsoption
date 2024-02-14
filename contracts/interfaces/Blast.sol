//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.20;

interface IBlast {
    // Note: the full interface for IBlast can be found below
    function configureClaimableGas() external;

    function claimAllGas(
        address contractAddress,
        address recipient
    ) external returns (uint256);
}
