// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AwStake} from "../src/AwStake.sol";
import {AwToken} from "../src/AwToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract TestableAwStake is AwStake {
    function testGrantRole(bytes32 role, address account) external {
        _grantRole(role, account);
    }
}

contract AwStakeTest is Test {
    TestableAwStake internal stake;
    AwToken internal aw;

    address internal admin; // 作为管理员且充当一个质押用户
    address internal user1;
    address internal user2;

    uint256 internal constant ONE = 1e18;

    function setUp() public {
        admin = address(this);
        user1 = address(0x1111);
        user2 = address(0x2222);

        // 部署奖励代币 AwToken 并初始化，admin 获取 MINTER/ADMIN/BURNER 角色
        aw = new AwToken();
        aw.initialize(admin);

        // 部署可测试的质押合约并初始化
        stake = new TestableAwStake();
        uint256 start = block.number + 5;
        uint256 end = start + 10_000;
        uint256 rewardPerBlock = 1 * ONE; // 1e18 精度
        stake.initialize(admin, start, end, rewardPerBlock);

        // 设置奖励代币为 AwToken
        stake.setRewardToken(IERC20(address(aw)));

        // 添加原生币池（pool 0）
        stake.addStakePool(address(0), 1, 1, 10);

        // 添加 ERC20 质押池（pool 1，使用 AwToken 作为质押代币）
        stake.addStakePool(address(aw), 1, 1, 10);

        // 资金准备：为质押合约铸造奖励资金
        aw.mint(address(stake), 1_000_000 * ONE);

        // 为用户铸造一些代币用于质押
        aw.mint(admin, 10_000 * ONE);
        aw.mint(user1, 10_000 * ONE);
        aw.mint(user2, 10_000 * ONE);

        // 赋权：由于 deposit 内部调用了 onlyRole(ADMIN_ROLE) 的 updateStakePoolReward，
        // 需要为多用户授予 ADMIN_ROLE 以便测试非管理员地址可质押
        bytes32 ADMIN_ROLE = stake.ADMIN_ROLE();
        stake.testGrantRole(ADMIN_ROLE, user1);
        stake.testGrantRole(ADMIN_ROLE, user2);

        // 将区块设置到奖励开始前一块，确保各测试自行推进到奖励开始
        vm.roll(start - 1);
    }

    function test_initialize_roles() public view {
        // 简单检查初始化后状态
        assertEq(address(stake.rewardToken()), address(aw));
    }

    function test_stake_claim_award_erc20_pool() public {
        uint256 poolId = 1; // ERC20 pool (AwToken)
        uint256 amount = 100 * ONE;

        // 授权并质押（必须由具备 ADMIN_ROLE 的账户发起）
        aw.approve(address(stake), amount);
        stake.deposit(poolId, amount);

        // 推进到奖励开始后 100 区块
        uint256 before = aw.balanceOf(admin);
        vm.roll(stake.rewardStartBlock() + 100);

        // 领取奖励
        stake.claim(poolId);
        uint256 afterBal = aw.balanceOf(admin);
        assertGt(afterBal, before, "claim should transfer rewards to admin");
    }

    function test_unstake_and_withdraw_when_unlocked() public {
        uint256 poolId = 1; // ERC20 pool (AwToken)
        uint256 amount = 50 * ONE;

        // 先质押
        aw.approve(address(stake), amount);
        stake.deposit(poolId, amount);

        // 解质押一部分，产生解质押请求
        uint256 unstakeAmt = 20 * ONE;
        stake.unstake(poolId, unstakeAmt);

        // 未到解锁区块时 withdraw 不会转账
        uint256 balBefore = aw.balanceOf(admin);
        stake.withdraw(poolId, 0);
        assertEq(aw.balanceOf(admin), balBefore, "no withdraw before unlock");

        // 推进区块到解锁（初始化时锁定 10 个区块）
        vm.roll(stake.rewardStartBlock() + 12);

        // 提现应到账
        stake.withdraw(poolId, 0);
        uint256 balAfter = aw.balanceOf(admin);
        assertEq(
            balAfter,
            balBefore + unstakeAmt,
            "withdraw should transfer unstaked tokens"
        );
    }

    function test_deposit_native_pool0_and_claim() public {
        // 向合约发送一些以太用作原生质押
        uint256 nativeAmt = 1 ether;
        vm.deal(admin, nativeAmt);

        // pool 0 为原生币池
        stake.depositNative{value: nativeAmt}();

        // 推进到奖励开始后 50 区块
        vm.roll(stake.rewardStartBlock() + 50);

        // 领取奖励（奖励为 AwToken，从合约余额中发放）
        uint256 before = aw.balanceOf(admin);
        stake.claim(0);
        uint256 afterBal = aw.balanceOf(admin);
        assertGt(
            afterBal,
            before,
            "claim on native pool should pay rewards in AwToken"
        );
    }

    function test_multi_users_stake_and_claim_proportional() public {
        uint256 poolId = 1;
        uint256 a1 = 200 * ONE;
        uint256 a2 = 800 * ONE;

        // user1 质押
        vm.startPrank(user1);
        aw.approve(address(stake), a1);
        stake.deposit(poolId, a1);
        vm.stopPrank();

        // user2 质押（同一区块，简化分配验证）
        vm.startPrank(user2);
        aw.approve(address(stake), a2);
        stake.deposit(poolId, a2);
        vm.stopPrank();

        // 推进到奖励开始后 200 区块，以便严格按比例分配
        vm.roll(stake.rewardStartBlock() + 200);

        // 记录前余额并领取
        vm.startPrank(user1);
        uint256 u1Before = aw.balanceOf(user1);
        stake.claim(poolId);
        uint256 u1Reward = aw.balanceOf(user1) - u1Before;
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 u2Before = aw.balanceOf(user2);
        stake.claim(poolId);
        uint256 u2Reward = aw.balanceOf(user2) - u2Before;
        vm.stopPrank();

        // 奖励应近似按质押占比分配：u1Reward * a2 ≈ u2Reward * a1
        // 允许 1e12 的整数舍入误差
        uint256 left = (u1Reward * a2) / ONE; // 归一化避免溢出
        uint256 right = (u2Reward * a1) / ONE;
        if (left > right) {
            assertLe(
                left - right,
                1e12,
                "proportional rewards mismatch (left>right)"
            );
        } else {
            assertLe(
                right - left,
                1e12,
                "proportional rewards mismatch (right>left)"
            );
        }
    }

    function test_print_event_logs_reward_update() public {
        uint256 poolId = 1;

        // 先准备轻量质押以激活奖励累计
        aw.approve(address(stake), 1 * ONE);
        stake.deposit(poolId, 1 * ONE);

        // 跳到奖励开始后若干区块，确保会有奖励可累计
        vm.roll(stake.rewardStartBlock() + 5);

        // 记录日志，再调用只限管理员的奖励更新
        vm.recordLogs();
        stake.updateStakePoolReward(poolId);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // 事件签名
        bytes32 REWARD_SIG = keccak256(
            bytes("StakePoolRewardUpdated(uint256,uint256,uint256)")
        );

        for (uint256 i = 0; i < entries.length; i++) {
            Vm.Log memory log = entries[i];
            if (log.topics.length > 0 && log.topics[0] == REWARD_SIG) {
                uint256 stakePoolId = uint256(log.topics[1]);
                (uint256 lastRewardBlock, uint256 addedReward) = abi.decode(
                    log.data,
                    (uint256, uint256)
                );

                console2.log(
                    string(
                        abi.encodePacked(
                            "StakePoolRewardUpdated ",
                            "stakePoolId:",
                            Strings.toString(stakePoolId),
                            " ",
                            "lastRewardBlock:",
                            Strings.toString(lastRewardBlock),
                            " ",
                            "addedReward:",
                            Strings.toString(addedReward)
                        )
                    )
                );
            }
        }
    }

    function test_print_all_events() public {
        // 触发全量事件：创建池、参数更新、质押/解质押/提现/领取/奖励更新
        uint256 erc20Pool = 1;

        // 记录日志
        vm.recordLogs();

        // 1) 新增一个 ERC20 池（将触发 StakePoolCreated）
        stake.addStakePool(address(aw), 2, 5, 20);

        // 2) 更新池参数（权重/最小额/锁仓期）
        stake.updateStakePoolWeight(erc20Pool, 3);
        stake.updateStakePoolMinStakeAmount(erc20Pool, 2);
        stake.updateStakePoolUnstakeLockedBlocks(erc20Pool, 12);

        // 3) 质押（触发 StakePoolUserDeposited）
        aw.approve(address(stake), 100 * ONE);
        stake.deposit(erc20Pool, 100 * ONE);

        // 4) 奖励更新（触发 StakePoolRewardUpdated）
        vm.roll(stake.rewardStartBlock() + 10);
        stake.updateStakePoolReward(erc20Pool);

        // 5) 解质押（触发 RequestedUnstake）
        stake.unstake(erc20Pool, 40 * ONE);

        // 6) 提现（触发 Withdraw）
        vm.roll(block.number + 20);
        stake.withdraw(erc20Pool, 0);

        // 7) 领取奖励（触发 ClaimedReward）
        stake.claim(erc20Pool);

        // 获取并解析日志
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 SIG_StakePoolCreated = keccak256(
            "StakePoolCreated(uint256,address,uint256,uint256,uint256)"
        );
        bytes32 SIG_StakePoolWeightUpdated = keccak256(
            "StakePoolWeightUpdated(uint256,uint256)"
        );
        bytes32 SIG_StakePoolMinStakeAmountUpdated = keccak256(
            "StakePoolMinStakeAmountUpdated(uint256,uint256)"
        );
        bytes32 SIG_StakePoolUnstakeLockedBlocksUpdated = keccak256(
            "StakePoolUnstakeLockedBlocksUpdated(uint256,uint256)"
        );
        bytes32 SIG_StakePoolRewardUpdated = keccak256(
            "StakePoolRewardUpdated(uint256,uint256,uint256)"
        );
        bytes32 SIG_StakePoolUserDeposited = keccak256(
            "StakePoolUserDeposited(uint256,address,uint256)"
        );
        bytes32 SIG_RequestedUnstake = keccak256(
            "RequestedUnstake(uint256,address,uint256)"
        );
        bytes32 SIG_Withdraw = keccak256(
            "Withdraw(uint256,address,uint256,uint256)"
        );
        bytes32 SIG_ClaimedReward = keccak256(
            "ClaimedReward(address,uint256,uint256)"
        );

        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            bytes32 sig = log.topics.length > 0 ? log.topics[0] : bytes32(0);

            if (sig == SIG_StakePoolCreated) {
                uint256 poolId = uint256(log.topics[1]);
                address token = address(uint160(uint256(log.topics[2])));
                (
                    uint256 weight,
                    uint256 minStakeAmount,
                    uint256 lockedBlocks
                ) = abi.decode(log.data, (uint256, uint256, uint256));
                console2.log(
                    string(
                        abi.encodePacked(
                            "StakePoolCreated ",
                            "poolId:",
                            Strings.toString(poolId),
                            " ",
                            "token:",
                            Strings.toHexString(uint160(token), 20),
                            " ",
                            "weight:",
                            Strings.toString(weight),
                            " ",
                            "minStakeAmount:",
                            Strings.toString(minStakeAmount),
                            " ",
                            "unstakeLockedBlocks:",
                            Strings.toString(lockedBlocks)
                        )
                    )
                );
            } else if (sig == SIG_StakePoolWeightUpdated) {
                (uint256 poolId, uint256 weight) = abi.decode(
                    log.data,
                    (uint256, uint256)
                );
                console2.log(
                    string(
                        abi.encodePacked(
                            "StakePoolWeightUpdated ",
                            "poolId:",
                            Strings.toString(poolId),
                            " ",
                            "weight:",
                            Strings.toString(weight)
                        )
                    )
                );
            } else if (sig == SIG_StakePoolMinStakeAmountUpdated) {
                uint256 poolId = uint256(log.topics[1]);
                uint256 minStakeAmount = abi.decode(log.data, (uint256));
                console2.log(
                    string(
                        abi.encodePacked(
                            "StakePoolMinStakeAmountUpdated ",
                            "poolId:",
                            Strings.toString(poolId),
                            " ",
                            "minStakeAmount:",
                            Strings.toString(minStakeAmount)
                        )
                    )
                );
            } else if (sig == SIG_StakePoolUnstakeLockedBlocksUpdated) {
                uint256 poolId = uint256(log.topics[1]);
                uint256 lockedBlocks = abi.decode(log.data, (uint256));
                console2.log(
                    string(
                        abi.encodePacked(
                            "StakePoolUnstakeLockedBlocksUpdated ",
                            "poolId:",
                            Strings.toString(poolId),
                            " ",
                            "unstakeLockedBlocks:",
                            Strings.toString(lockedBlocks)
                        )
                    )
                );
            } else if (sig == SIG_StakePoolRewardUpdated) {
                uint256 poolId = uint256(log.topics[1]);
                (uint256 lastRewardBlock, uint256 addedReward) = abi.decode(
                    log.data,
                    (uint256, uint256)
                );
                console2.log(
                    string(
                        abi.encodePacked(
                            "StakePoolRewardUpdated ",
                            "poolId:",
                            Strings.toString(poolId),
                            " ",
                            "lastRewardBlock:",
                            Strings.toString(lastRewardBlock),
                            " ",
                            "addedReward:",
                            Strings.toString(addedReward)
                        )
                    )
                );
            } else if (sig == SIG_StakePoolUserDeposited) {
                uint256 poolId = uint256(log.topics[1]);
                address user = address(uint160(uint256(log.topics[2])));
                uint256 amount = abi.decode(log.data, (uint256));
                console2.log(
                    string(
                        abi.encodePacked(
                            "StakePoolUserDeposited ",
                            "poolId:",
                            Strings.toString(poolId),
                            " ",
                            "user:",
                            Strings.toHexString(uint160(user), 20),
                            " ",
                            "amount:",
                            Strings.toString(amount)
                        )
                    )
                );
            } else if (sig == SIG_RequestedUnstake) {
                uint256 poolId = uint256(log.topics[1]);
                address user = address(uint160(uint256(log.topics[2])));
                uint256 amount = abi.decode(log.data, (uint256));
                console2.log(
                    string(
                        abi.encodePacked(
                            "RequestedUnstake ",
                            "poolId:",
                            Strings.toString(poolId),
                            " ",
                            "user:",
                            Strings.toHexString(uint160(user), 20),
                            " ",
                            "amount:",
                            Strings.toString(amount)
                        )
                    )
                );
            } else if (sig == SIG_Withdraw) {
                uint256 poolId = uint256(log.topics[1]);
                address user = address(uint160(uint256(log.topics[2])));
                (uint256 amount, uint256 blk) = abi.decode(
                    log.data,
                    (uint256, uint256)
                );
                console2.log(
                    string(
                        abi.encodePacked(
                            "Withdraw ",
                            "poolId:",
                            Strings.toString(poolId),
                            " ",
                            "user:",
                            Strings.toHexString(uint160(user), 20),
                            " ",
                            "amount:",
                            Strings.toString(amount),
                            " ",
                            "blockNumber:",
                            Strings.toString(blk)
                        )
                    )
                );
            } else if (sig == SIG_ClaimedReward) {
                address user = address(uint160(uint256(log.topics[1])));
                uint256 poolId = uint256(log.topics[2]);
                uint256 amount = abi.decode(log.data, (uint256));
                console2.log(
                    string(
                        abi.encodePacked(
                            "ClaimedReward ",
                            "user:",
                            Strings.toHexString(uint160(user), 20),
                            " ",
                            "poolId:",
                            Strings.toString(poolId),
                            " ",
                            "amount:",
                            Strings.toString(amount)
                        )
                    )
                );
            }
        }
    }
}
