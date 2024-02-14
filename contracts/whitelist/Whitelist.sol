// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Whitelist {
    mapping(address => bool) public whitelistedAddresses;

    function addAddressToWhitelist(address _addressToWhitelist) public {
        require(
            msg.sender == 0x9e522293cF4e5Ffcc0CC7709468379F1edfeED1D,
            "Only Owner can add to whitelist!"
        );
        require(!whitelistedAddresses[_addressToWhitelist], "Already in!");
        whitelistedAddresses[_addressToWhitelist] = true;
    }
}
