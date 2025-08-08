// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import 'forge-std/Script.sol';
import { ERC1967Proxy } from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { AwStake } from '../src/AwStake.sol';
import { Upgrades } from '@openzeppelin/foundry-upgrades/Upgrades.sol';

contract DeployAwStake is Script {
    function run() external {
        uint deployerPrivateKey = vm.envUint('PRIVATE_KEY');
        address admin = vm.addr(deployerPrivateKey);
        uint rewardStartBlock = vm.envUint('REWARD_START_BLOCK');
        uint rewardEndBlock = vm.envUint('REWARD_END_BLOCK');
        uint rewardPerBlock = vm.envUint('REWARD_PER_BLOCK');

        vm.startBroadcast(deployerPrivateKey);
        bytes memory initData =
            abi.encodeCall(AwStake.initialize, (admin, rewardStartBlock, rewardEndBlock, rewardPerBlock));

        AwStake awStake = AwStake(Upgrades.deployUUPSProxy('AwStake.sol:AwStake', initData));

        // 可选：设置奖励代币（如果提供环境变量 REWARD_TOKEN）
        // 需要当前广播账户具备 ADMIN_ROLE（通常与 ADMIN 相同）
        try vm.envAddress('REWARD_TOKEN') returns (address rewardTokenAddr) {
            if (rewardTokenAddr != address(0)) {
                awStake.setRewardToken(IERC20(rewardTokenAddr));
            }
        } catch { }

        vm.stopBroadcast();
    }
}
