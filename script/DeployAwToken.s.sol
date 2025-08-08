// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AwToken} from "../src/AwToken.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";

contract DeployAwToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        bytes memory initData = abi.encodeCall(AwToken.initialize, (admin));

        AwToken awToken = AwToken(
            Upgrades.deployUUPSProxy("AwToken.sol:AwToken", initData)
        );

        awToken.balanceOf(admin);

        vm.stopBroadcast();
    }
}
