// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { UUPSUpgradeable } from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import { AccessControlUpgradeable } from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import { PausableUpgradeable } from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import { SafeERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { Address } from '@openzeppelin/contracts/utils/Address.sol';

/**
 * @title AwStake
 * @author AwStake
 * @notice Staking contract for AwStake
 */
contract AwStake is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256('admin_role'); //配置参数
    bytes32 public constant UPGRADE_ROLE = keccak256('upgrade_role'); //升级权限
    bytes32 public constant PAUSE_ROLE = keccak256('pause_role'); //暂停权限

    using SafeERC20 for IERC20; //安全操作ERC20
    using Math for uint; //数学操作
    using Address for address; //地址操作

    struct StakePool {
        address token; //质押token
        uint weight; //质押权重
        uint totalStaked; //总质押量
        uint totalRewards; //总奖励, 精度1e18
        uint totalUsers; //总用户数
        uint totalRewardsClaimed; //总奖励领取量
        uint lastRewardBlock; //上次奖励区块
        uint minStakeAmount; //最小质押量
        uint unstakeLockedBlocks; //解质押锁定期, 单位区块, 0表示不锁仓
    }

    struct UserStake {
        uint amount; //质押量
        uint finishedReward; //已领取奖励, 精度1e18
        uint pendingReward; //待领取奖励, 精度1e18
        UnstakeRequest[] unstakeRequests; //解质押请求列表
    }

    struct UnstakeRequest {
        uint amount; //解质押量
        uint unlockBlock; //解质押解锁区块
    }

    IERC20 public rewardToken; //奖励token
    uint public rewardStartBlock; //奖励开始区块
    uint public rewardEndBlock; //奖励结束区块
    uint public rewardPerBlock; //每区块奖励, 精度1e18
    uint public totalStakeWeight; //总质押权重

    bool public withdrawable; //是否可提现
    bool public stakable; //是否可质押
    bool public unstakable; //是否可解质押
    bool public claimable; //是否可领取奖励

    StakePool[] public stakePools; //质押池
    mapping(uint stakePoolId => mapping(address user => UserStake userStake)) public userStakes; //用户质押量

    /**
     * @notice 质押池创建
     * @param stakePoolId 质押池ID
     * @param token 质押token
     * @param weight 质押权重
     * @param minStakeAmount 最小质押量
     * @param unstakeLockedBlocks 解质押锁定期, 单位区块, 0表示不锁仓
     */
    event StakePoolCreated(
        uint indexed stakePoolId, address indexed token, uint weight, uint minStakeAmount, uint unstakeLockedBlocks
    );

    /**
     * @notice 质押
     * @param stakePoolId 质押池ID
     * @param user 用户
     * @param amount 质押量
     * @param rewardDebt 奖励欠款
     * @param lastRewardBlock 上次奖励区块
     */
    event Staked(uint indexed stakePoolId, address indexed user, uint amount, uint rewardDebt, uint lastRewardBlock);

    /**
     * @notice 解质押
     * @param stakePoolId 质押池ID
     * @param user 用户
     * @param amount 解质押量
     */
    event Unstaked(uint indexed stakePoolId, address indexed user, uint amount);

    /**
     * @notice 领取奖励
     * @param stakePoolId 质押池ID
     * @param user 用户
     * @param amount 领取奖励量
     */
    event RewardsClaimed(uint indexed stakePoolId, address indexed user, uint amount);

    /**
     * @notice 请求解质押
     * @param stakePoolId 质押池ID
     * @param user 用户
     * @param amount 请求解质押量
     */
    event RequestedUnstake(uint indexed stakePoolId, address indexed user, uint amount);

    /**
     * @notice 质押池权重更新
     * @param stakePoolId 质押池ID
     * @param weight 质押权重
     */
    event StakePoolWeightUpdated(uint stakePoolId, uint weight);

    /**
     * @notice 质押池最小质押量更新
     * @param stakePoolId 质押池ID
     * @param minStakeAmount 最小质押量
     */
    event StakePoolMinStakeAmountUpdated(uint indexed stakePoolId, uint minStakeAmount);

    /**
     * @notice 质押池解质押锁定期更新
     * @param stakePoolId 质押池ID
     * @param unstakeLockedBlocks 解质押锁定期, 单位区块, 0表示不锁仓
     */
    event StakePoolUnstakeLockedBlocksUpdated(uint indexed stakePoolId, uint unstakeLockedBlocks);

    /**
     * @notice 质押池奖励更新
     * @param stakePoolId 质押池ID
     * @param lastRewardBlock 上次奖励区块
     * @param addedReward 增加的奖励
     */
    event StakePoolRewardUpdated(uint indexed stakePoolId, uint lastRewardBlock, uint addedReward);

    /**
     * @notice 用户质押
     * @param stakePoolId 质押池ID
     * @param user 用户
     * @param amount 质押量
     */
    event StakePoolUserDeposited(uint indexed stakePoolId, address indexed user, uint amount);

    /**
     * @notice 提现
     * @param stakePoolId 质押池ID
     * @param user 用户
     * @param amount 提现量
     * @param blockNumber 提现区块
     */
    event Withdraw(uint indexed stakePoolId, address indexed user, uint amount, uint blockNumber);

    /**
     * @notice 领取奖励
     * @param user 用户
     * @param stakePoolId 质押池ID
     * @param amount 领取奖励量
     */
    event ClaimedReward(address indexed user, uint indexed stakePoolId, uint amount);

    /**
     * @notice 有效质押池
     * @param _stakePoolId 质押池ID
     */
    modifier effectiveStakePool(uint _stakePoolId) {
        require(_stakePoolId < stakePools.length, 'invalid stakePoolId');
        _;
    }

    /**
     * @notice 初始化
     * @param __initAdmin 初始化管理员
     * @param _rewardStartBlock 奖励开始区块
     * @param _rewardEndBlock 奖励结束区块
     * @param _rewardPerBlock 每区块奖励, 精度1e18
     */
    function initialize(
        address __initAdmin,
        uint _rewardStartBlock,
        uint _rewardEndBlock,
        uint _rewardPerBlock
    )
        public
        initializer
    {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(ADMIN_ROLE, __initAdmin);
        _grantRole(UPGRADE_ROLE, __initAdmin);
        _grantRole(PAUSE_ROLE, __initAdmin);
        rewardStartBlock = _rewardStartBlock;
        rewardEndBlock = _rewardEndBlock;
        rewardPerBlock = _rewardPerBlock;
        withdrawable = true;
        stakable = true;
        unstakable = true;
        claimable = true;
    }

    /**
     * @notice 设置奖励token 必须为ERC20 且为合约地址 (只有管理员可以设置)
     * @param _rewardToken 奖励token
     */
    function setRewardToken(IERC20 _rewardToken) public onlyRole(ADMIN_ROLE) {
        require(address(_rewardToken) != address(0), 'rewardToken must be a valid address');
        rewardToken = _rewardToken;
    }

    /**
     * @notice 设置奖励开始区块 (只有管理员可以设置)
     * @param _rewardStartBlock 奖励开始区块
     */
    function setRewardStartBlock(uint _rewardStartBlock) public onlyRole(ADMIN_ROLE) {
        require(
            _rewardStartBlock > block.number && _rewardStartBlock < rewardEndBlock,
            'rewardStartBlock must be greater than current block number and less than rewardEndBlock'
        );
        rewardStartBlock = _rewardStartBlock;
    }

    /**
     * @notice 设置奖励结束区块 (只有管理员可以设置)
     * @param _rewardEndBlock 奖励结束区块
     */
    function setRewardEndBlock(uint _rewardEndBlock) public onlyRole(ADMIN_ROLE) {
        require(
            _rewardEndBlock > block.number && _rewardEndBlock > rewardStartBlock,
            'rewardEndBlock must be greater than current block number and rewardStartBlock'
        );
        rewardEndBlock = _rewardEndBlock;
    }

    /**
     * @notice 设置每区块奖励 (只有管理员可以设置)
     * @param _rewardPerBlock 每区块奖励, 精度1e18
     */
    function setRewardPerBlock(uint _rewardPerBlock) public onlyRole(ADMIN_ROLE) {
        require(_rewardPerBlock > 0, 'rewardPerBlock must be greater than 0');
        rewardPerBlock = _rewardPerBlock;
    }

    /**
     * @notice 设置是否可提现 (只有管理员可以设置)
     * @param _withdrawable 是否可提现
     */
    function setWithdrawable(bool _withdrawable) public onlyRole(ADMIN_ROLE) {
        withdrawable = _withdrawable;
    }

    /**
     * @notice 设置是否可质押 (只有管理员可以设置)
     * @param _stakable 是否可质押
     */
    function setStakable(bool _stakable) public onlyRole(ADMIN_ROLE) {
        stakable = _stakable;
    }

    /**
     * @notice 设置是否可解质押 (只有管理员可以设置)
     * @param _unstakable 是否可解质押
     */
    function setUnstakable(bool _unstakable) public onlyRole(ADMIN_ROLE) {
        unstakable = _unstakable;
    }

    /**
     * @notice 设置是否可领取奖励 (只有管理员可以设置)
     * @param _claimable 是否可领取奖励
     */
    function setClaimable(bool _claimable) public onlyRole(ADMIN_ROLE) {
        claimable = _claimable;
    }

    /**
     * @notice 授权升级
     * @param newImplementation 新实现地址
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADE_ROLE) { }

    /**
     * @notice 暂停
     */
    function pause() public onlyRole(PAUSE_ROLE) {
        _pause();
    }

    /**
     * @notice 恢复
     */
    function unpause() public onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    /**
     * @notice 添加质押池, 第一个质押池必须为0地址(默认ETH), 后续的质押池必须为有效地址
     * @param _token 质押token
     * @param _weight 质押权重
     * @param _minStakeAmount 最小质押量
     * @param _unstakeLockedBlocks 解质押锁定期, 单位区块, 0表示不锁仓
     */
    function addStakePool(
        address _token,
        uint _weight,
        uint _minStakeAmount,
        uint _unstakeLockedBlocks
    )
        external
        virtual
        onlyRole(ADMIN_ROLE)
    {
        if (stakePools.length == 0) {
            require(_token == address(0), 'token must be address(0)');
        } else {
            require(_token != address(0), 'token must be a valid address');
        }

        require(_weight > 0, 'weight must be greater than 0');
        require(_minStakeAmount > 0, 'minStakeAmount must be greater than 0');
        require(_unstakeLockedBlocks > 0, 'unstakeLockedBlocks must be greater than 0');

        // 设置初始的奖励区块从哪里开始计算
        uint _lastRewardBlock = block.number > rewardStartBlock ? block.number : rewardStartBlock;

        // 更新总质押权重
        totalStakeWeight += _weight;

        // 添加质押池
        stakePools.push(
            StakePool({
                token: _token,
                weight: _weight,
                totalStaked: 0,
                totalRewards: 0,
                totalUsers: 0,
                totalRewardsClaimed: 0,
                lastRewardBlock: _lastRewardBlock,
                minStakeAmount: _minStakeAmount,
                unstakeLockedBlocks: _unstakeLockedBlocks
            })
        );

        // 触发质押池创建事件
        emit StakePoolCreated(stakePools.length - 1, _token, _weight, _minStakeAmount, _unstakeLockedBlocks);
    }

    /**
     * @notice 更新质押池权重
     * @param _stakePoolId 质押池ID
     * @param _weight 质押权重
     */
    function updateStakePoolWeight(
        uint _stakePoolId,
        uint _weight
    )
        external
        virtual
        onlyRole(ADMIN_ROLE)
        effectiveStakePool(_stakePoolId)
    {
        require(_weight > 0, 'weight must be greater than 0');
        // 更新总质押权重, 先减去旧的权重, 再加上新的权重
        totalStakeWeight = totalStakeWeight - stakePools[_stakePoolId].weight + _weight;
        // 更新质押池权重
        stakePools[_stakePoolId].weight = _weight;

        emit StakePoolWeightUpdated(_stakePoolId, _weight);
    }

    /**
     * @notice 更新质押池最小质押量
     * @param _stakePoolId 质押池ID
     * @param _minStakeAmount 最小质押量
     */
    function updateStakePoolMinStakeAmount(
        uint _stakePoolId,
        uint _minStakeAmount
    )
        external
        virtual
        onlyRole(ADMIN_ROLE)
        effectiveStakePool(_stakePoolId)
    {
        require(_minStakeAmount > 0, 'minStakeAmount must be greater than 0');
        stakePools[_stakePoolId].minStakeAmount = _minStakeAmount;

        emit StakePoolMinStakeAmountUpdated(_stakePoolId, _minStakeAmount);
    }

    /**
     * @notice 更新质押池解质押锁定期
     * @param _stakePoolId 质押池ID
     * @param _unstakeLockedBlocks 解质押锁定期, 单位区块, 0表示不锁仓
     */
    function updateStakePoolUnstakeLockedBlocks(
        uint _stakePoolId,
        uint _unstakeLockedBlocks
    )
        external
        virtual
        onlyRole(ADMIN_ROLE)
        effectiveStakePool(_stakePoolId)
    {
        require(_unstakeLockedBlocks > 0, 'unstakeLockedBlocks must be greater than 0');
        stakePools[_stakePoolId].unstakeLockedBlocks = _unstakeLockedBlocks;

        emit StakePoolUnstakeLockedBlocksUpdated(_stakePoolId, _unstakeLockedBlocks);
    }

    /**
     * @notice 根据区块范围计算区块倍数
     * @param _fromBlock 开始区块
     * @param _toBlock 结束区块
     * @return 区块倍数
     */
    function _getMultiplierByBlockRange(uint _fromBlock, uint _toBlock) internal view returns (uint) {
        require(_fromBlock < _toBlock, 'invalid block range');

        if (_fromBlock < rewardStartBlock) {
            _fromBlock = rewardStartBlock;
        }

        if (_toBlock > rewardEndBlock) {
            _toBlock = rewardEndBlock;
        }
        require(_fromBlock < _toBlock, 'fromBlock must be less than toBlock');
        (bool success, uint multiplier) = (_toBlock - _fromBlock).tryMul(rewardPerBlock);
        if (!success) {
            revert('rewardPerBlock * (toBlock - fromBlock) overflow');
        }
        return multiplier;
    }

    /**
     * @notice 获取用户质押量
     * @param _stakePoolId 质押池ID
     * @param _user 用户
     * @return 用户质押量
     */
    function _getUserStakeInfo(uint _stakePoolId, address _user) internal view returns (UserStake memory) {
        return userStakes[_stakePoolId][_user];
    }

    /**
     * @notice 获取用户质押量
     * @param _stakePoolId 质押池ID
     * @return 用户质押量
     */
    function getUserStakeAmount(uint _stakePoolId) external view effectiveStakePool(_stakePoolId) returns (uint) {
        return _getUserStakeInfo(_stakePoolId, msg.sender).amount;
    }

    /**
     * @notice 获取在特定区块的待领取奖励
     * @param _stakePoolId 质押池ID
     * @param _user 用户
     * @param _block 区块
     * @return 用户奖励欠款
     */
    function getPendingRewardByBlock(
        uint _stakePoolId,
        address _user,
        uint _block
    )
        public
        view
        effectiveStakePool(_stakePoolId)
        returns (uint)
    {
        UserStake memory userStake = _getUserStakeInfo(_stakePoolId, _user);
        StakePool memory stakePool = stakePools[_stakePoolId];

        // 获取质押池的总奖励和总质押量
        uint stakePoolTotalRewards = stakePool.totalRewards;
        uint stakePoolTotalStaked = stakePool.totalStaked;

        if (_block > stakePool.lastRewardBlock && stakePoolTotalStaked > 0) {
            uint multiplier = _getMultiplierByBlockRange(stakePool.lastRewardBlock, _block);

            uint stakePoolRewardWithWeight = _calculateStakePoolRewardWithWeight(stakePool, multiplier);

            stakePoolTotalRewards += (stakePoolRewardWithWeight * 1e18) / stakePoolTotalStaked;
        }

        // 计算用户待领取奖励, 公式: (用户质押量 * 质押池总奖励) / 1e18 - 已领取奖励 + 待领取奖励
        return ((userStake.amount * stakePoolTotalRewards) / 1e18) - userStake.finishedReward + userStake.pendingReward;
    }

    /**
     * @notice 计算质押池奖励, 包含权重
     * @param stakePool 质押池
     * @param multiplier 区块倍数
     * @return 质押池奖励
     */
    function _calculateStakePoolRewardWithWeight(
        StakePool memory stakePool,
        uint multiplier
    )
        internal
        view
        returns (uint)
    {
        // 计算质押池奖励, 包含权重
        (bool success, uint stakePoolRewardWithWeight) = multiplier.tryMul(stakePool.weight);

        if (!success) {
            revert('multiplier * weight overflow');
        }
        (success, stakePoolRewardWithWeight) = stakePoolRewardWithWeight.tryDiv(totalStakeWeight);

        if (!success) {
            revert('weight / totalStakeWeight overflow');
        }

        return stakePoolRewardWithWeight;
    }

    /**
     * @notice 更新质押池奖励
     * @param _stakePoolId 质押池ID
     */
    function updateStakePoolReward(uint _stakePoolId)
        public
        virtual
        onlyRole(ADMIN_ROLE)
        effectiveStakePool(_stakePoolId)
    {
        StakePool storage stakePool = stakePools[_stakePoolId];
        // 如果区块小于上次奖励区块, 或者总质押量为0, 则不更新奖励
        if (block.number <= stakePool.lastRewardBlock || stakePool.totalStaked <= 0) {
            return;
        }

        // 计算区块倍数
        uint multiplier = _getMultiplierByBlockRange(stakePool.lastRewardBlock, block.number);

        // 计算质押池奖励
        uint stakePoolRewardWithWeight = _calculateStakePoolRewardWithWeight(stakePool, multiplier);

        // accRewardPerShare 累加：acc += reward * 1e18 / totalStaked

        (bool success, uint addedPerShare) = (stakePoolRewardWithWeight).tryMul(1e18);
        if (!success) {
            revert('stakePoolRewardWithWeight * 1e18 overflow');
        }

        uint addedReward;
        (success, addedReward) = addedPerShare.tryDiv(stakePool.totalStaked);
        if (!success) {
            revert('(reward * 1e18) / totalStaked overflow');
        }
        (success, stakePool.totalRewards) = stakePool.totalRewards.tryAdd(addedReward);
        if (!success) {
            revert('accRewardPerShare add overflow');
        }

        // 更新上次奖励区块
        stakePool.lastRewardBlock = block.number;

        // 触发质押池奖励更新事件
        emit StakePoolRewardUpdated(_stakePoolId, stakePool.lastRewardBlock, addedReward);
    }

    /**
     * @notice 批量更新质押池奖励
     */
    function massUpdateStakePoolReward() public virtual onlyRole(ADMIN_ROLE) {
        for (uint i = 0; i < stakePools.length; i++) {
            updateStakePoolReward(i);
        }
    }

    function _deposit(uint _stakePoolId, uint _amount) internal {
        if (_amount <= 0) {
            revert('amount must be greater than 0');
        }

        StakePool storage stakePool = stakePools[_stakePoolId];
        UserStake storage userStake = userStakes[_stakePoolId][msg.sender];

        // 更新质押池奖励
        updateStakePoolReward(_stakePoolId);

        // 添加用户
        if (userStake.amount == 0) {
            stakePool.totalUsers++;
        }

        // 已有质押，则更新用户待领取奖励
        if (userStake.amount > 0) {
            _updateUserPendingReward(stakePool, userStake);
        }

        // 添加用户质押
        if (_amount > 0) {
            _addUserStake(stakePool, userStake, _amount);
        }
        emit StakePoolUserDeposited(_stakePoolId, msg.sender, _amount);
    }

    /**
     * @notice 添加用户质押
     * @param _stakePool 质押池
     * @param _userStake 用户质押
     * @param _amount 质押量
     */
    function _addUserStake(StakePool storage _stakePool, UserStake storage _userStake, uint _amount) internal {
        bool success;
        uint newAmount;
        (success, newAmount) = _amount.tryAdd(_userStake.amount);
        if (!success) {
            revert('amount + userStake.amount overflow');
        }
        _userStake.amount = newAmount;

        uint newTotalStaked;
        (success, newTotalStaked) = _stakePool.totalStaked.tryAdd(_amount);
        if (!success) {
            revert('totalStaked + amount overflow');
        }

        // 如果总质押量发生变化, 则更新总质押量
        if (newTotalStaked != _stakePool.totalStaked) {
            _stakePool.totalStaked = newTotalStaked;
        }

        // 计算用户已领取奖励
        uint finishedReward = _calculateFinishedReward(_stakePool, _userStake);
        if (finishedReward != _userStake.finishedReward) {
            _userStake.finishedReward = finishedReward;
        }
    }

    function _calculateFinishedReward(
        StakePool storage _stakePool,
        UserStake storage _userStake
    )
        internal
        view
        returns (uint)
    {
        bool success;
        uint newFinishedReward;
        (success, newFinishedReward) = _userStake.amount.tryMul(_stakePool.totalRewards);
        if (!success) {
            revert('userStake.amount * totalRewards overflow');
        }
        (success, newFinishedReward) = newFinishedReward.tryDiv(1e18);
        if (!success) {
            revert('userStake.amount * totalRewards / 1e18 overflow');
        }

        return newFinishedReward;
    }

    function _subUserStake(StakePool storage _stakePool, UserStake storage _userStake, uint _amount) internal {
        // 更新用户质押量
        (bool success, uint newAmount) = _userStake.amount.trySub(_amount);
        if (!success) {
            revert('userStake.amount - amount overflow');
        }

        // 更新用户质押量
        if (newAmount != _userStake.amount) {
            _userStake.amount = newAmount;
        }

        // 添加解质押请求
        _userStake.unstakeRequests.push(
            UnstakeRequest({
                amount: _amount,
                // 解质押解锁区块 = 当前区块 + 解质押锁定期
                unlockBlock: block.number + _stakePool.unstakeLockedBlocks
            })
        );
    }

    /**
     * @notice 更新用户待领取奖励
     * @param _stakePool 质押池
     * @param _userStake 用户质押
     */
    function _updateUserPendingReward(StakePool storage _stakePool, UserStake storage _userStake) internal {
        uint pendingReward = _calculateUserPendingReward(_stakePool, _userStake);

        if (pendingReward != _userStake.pendingReward) {
            _userStake.pendingReward = pendingReward;
        }
    }

    /**
     * @notice 计算用户待领取奖励
     * @param _stakePool 质押池
     * @param _userStake 用户质押
     * @return 用户待领取奖励
     */
    function _calculateUserPendingReward(
        StakePool storage _stakePool,
        UserStake storage _userStake
    )
        internal
        view
        returns (uint)
    {
        (bool success, uint pendingReward) = _userStake.amount.tryMul(_stakePool.totalRewards);
        if (!success) {
            revert('userStake.amount * totalRewards overflow');
        }
        (success, pendingReward) = pendingReward.tryDiv(1e18);
        if (!success) {
            revert('userStake.amount * totalRewards / 1e18 overflow');
        }
        (success, pendingReward) = pendingReward.trySub(_userStake.finishedReward);
        if (!success) {
            revert('userStake.amount * totalRewards / 1e18 - finishedReward overflow');
        }
        if (pendingReward > 0) {
            (success, pendingReward) = pendingReward.tryAdd(_userStake.pendingReward);
            if (!success) {
                revert('pendingReward + userStake.pendingReward overflow');
            }
        }

        return pendingReward;
    }

    /**
     * @notice 质押
     * @param _stakePoolId 质押池ID
     * @param _amount 质押量
     */
    function deposit(uint _stakePoolId, uint _amount) external whenNotPaused effectiveStakePool(_stakePoolId) {
        if (_stakePoolId == 0) {
            revert('invalid stakePoolId, stakePoolId must be greater than 0');
        }

        StakePool storage stakePool = stakePools[_stakePoolId];
        if (stakePool.minStakeAmount > _amount) {
            revert('amount must be greater than minStakeAmount');
        }

        if (_amount > 0) {
            // 从用户账户中转移质押token到合约账户, 需要授权
            IERC20(stakePool.token).safeTransferFrom(msg.sender, address(this), _amount);
        }
        _deposit(_stakePoolId, _amount);
    }

    /**
     * @notice 质押原生币
     */
    function depositNative() external payable whenNotPaused {
        uint amount = msg.value;
        StakePool storage stakePool = stakePools[0];
        if (stakePool.minStakeAmount > amount) {
            revert('amount must be greater than minStakeAmount');
        }

        _deposit(0, amount);
    }

    function unstake(uint _stakePoolId, uint _amount) external whenNotPaused effectiveStakePool(_stakePoolId) {
        StakePool storage stakePool = stakePools[_stakePoolId];
        UserStake storage userStake = userStakes[_stakePoolId][msg.sender];

        if (userStake.amount < _amount) {
            revert('userStake.amount must be greater than amount');
        }

        if (_amount == 0) {
            revert('amount must be greater than 0');
        }

        updateStakePoolReward(_stakePoolId);

        _updateUserPendingReward(stakePool, userStake);

        // 更新用户质押量，并添加解质押请求
        _subUserStake(stakePool, userStake, _amount);
        // 更新总质押量
        (bool success, uint newTotalStaked) = stakePool.totalStaked.trySub(_amount);
        if (!success) {
            revert('totalStaked - amount overflow');
        }

        if (newTotalStaked != stakePool.totalStaked) {
            stakePool.totalStaked = newTotalStaked;
        }

        // 更新用户已结算奖励
        uint finishedReward = _calculateFinishedReward(stakePool, userStake);
        if (finishedReward != userStake.finishedReward) {
            userStake.finishedReward = finishedReward;
        }

        // 触发解质押事件
        emit RequestedUnstake(_stakePoolId, msg.sender, _amount);
    }

    /**
     * @notice 安全转账原生币
     * @param _to 接收地址
     * @param _amount 转账金额
     */
    function _safeNativeTransfer(address _to, uint _amount) internal {
        (bool success, bytes memory data) = _to.call{ value: _amount }('');
        if (!success) {
            revert('native transfer failed');
        }
        // 如果合约调用转账失败, 则抛出异常
        if (data.length > 0 && !abi.decode(data, (bool))) {
            revert('contract call transfer failed');
        }
    }

    /**
     * @notice 安全转账奖励代币
     * @param _to 接收地址
     * @param _amount 转账金额
     */
    function _safeRewardTokenTransfer(address _to, uint _amount) internal {
        uint balance = IERC20(rewardToken).balanceOf(address(this));
        if (_amount > balance) {
            revert('reward token balance is not enough');
        }
        IERC20(rewardToken).safeTransfer(_to, _amount);
    }

    /**
     * @notice 提现
     * @param _stakePoolId 质押池ID
     * @param _amount 提现量
     */
    function withdraw(uint _stakePoolId, uint _amount) external whenNotPaused effectiveStakePool(_stakePoolId) {
        StakePool storage stakePool = stakePools[_stakePoolId];
        UserStake storage userStake = userStakes[_stakePoolId][msg.sender];

        uint pendingWithdraw;
        uint popCount;

        // 计算用户待提现量
        for (uint i = 0; i < userStake.unstakeRequests.length; i++) {
            if (userStake.unstakeRequests[i].unlockBlock <= block.number) {
                pendingWithdraw += userStake.unstakeRequests[i].amount;
                popCount++;
            }
        }

        if (popCount > 0) {
            // 计算剩余解质押请求数量
            uint remain = userStake.unstakeRequests.length - popCount;
            if (remain > 0) {
                for (uint i = 0; i < remain; i++) {
                    userStake.unstakeRequests[i] = userStake.unstakeRequests[i + popCount];
                }
            }

            // 移除已解锁的解质押请求
            for (uint i = 0; i < popCount; i++) {
                userStake.unstakeRequests.pop();
            }
        }

        // 提现
        if (pendingWithdraw > 0) {
            if (stakePool.token == address(0)) {
                _safeNativeTransfer(msg.sender, pendingWithdraw);
            } else {
                IERC20(stakePool.token).safeTransfer(msg.sender, pendingWithdraw);
            }
        }

        emit Withdraw(_stakePoolId, msg.sender, _amount, block.number);
    }

    /**
     * @notice 领取奖励
     * @param _stakePoolId 质押池ID
     */
    function claim(uint _stakePoolId) external whenNotPaused {
        StakePool storage stakePool = stakePools[_stakePoolId];
        UserStake storage userStake = userStakes[_stakePoolId][msg.sender];
        updateStakePoolReward(_stakePoolId);

        // 始终计算待领取奖励
        uint pendingReward = _calculateUserPendingReward(stakePool, userStake);

        if (pendingReward > 0) {
            // 清空累积的 pending，并发放
            userStake.pendingReward = 0;
            _safeRewardTokenTransfer(msg.sender, pendingReward);

            // 更新已结算奖励
            uint finishedReward = _calculateFinishedReward(stakePool, userStake);
            if (finishedReward != userStake.finishedReward) {
                userStake.finishedReward = finishedReward;
            }
            emit ClaimedReward(msg.sender, _stakePoolId, pendingReward);
        }
    }
}
