# AwStake: Upgradeable Staking System

AwStake 是一个基于 OpenZeppelin Upgradeable 体系构建的可升级质押系统，提供多资产质押池、按权重分配奖励、解质押锁定与提现、暂停控制与访问控制等功能。项目使用 Foundry 进行开发、测试与部署。

## 项目架构

- 合约
  - `src/AwToken.sol`
    - 可升级的 ERC20 代币（UUPS + AccessControl + Ownable）
    - 角色：`ADMIN_ROLE`、`MINTER_ROLE`、`BURNER_ROLE`
    - 作为奖励代币或一般用途代币
  - `src/AwStake.sol`
    - 可升级的质押核心（UUPS + AccessControl + Pausable）
    - 多质押池（原生币/任意 ERC20）
    - 奖励按区块发放，支持权重，采用 accRewardPerShare 累计模型
    - 解质押请求 + 锁定区块 + 到期提现
    - 事件完备，便于追踪链上行为

- 脚本
  - `script/DeployAwToken.s.sol`：部署 `AwToken`（UUPS via ERC1967Proxy + initialize）
  - `script/DeployAwStake.s.sol`：部署 `AwStake`（UUPS via ERC1967Proxy + initialize），可选设置奖励代币

- 测试
  - `test/AwStake.t.sol`：覆盖初始化、质押/解质押/提现、奖励分发（含多用户比例）、事件日志打印等

- 依赖与工具
  - OpenZeppelin Contracts Upgradeable 5.4
  - Foundry（forge/anvil/cast）
  - Soldeer 管理依赖（`dependencies/` + `remappings.txt`）

## 功能概述

- 多池质押：
  - 池 0 支持原生币；其它池支持任意 ERC20
  - 每池配置：质押代币、权重、最小质押量、解质押锁定期
- 奖励分发：
  - `rewardStartBlock / rewardEndBlock / rewardPerBlock`
  - accRewardPerShare 累积，用户 `finishedReward/pendingReward` 分别计提
- 用户操作：
  - 质押 `deposit` / 原生质押 `depositNative`
  - 解质押 `unstake`（生成提现请求）
  - 提现 `withdraw`（到期释放）
  - 领取奖励 `claim`
- 管理能力：
  - 添加与配置质押池（权重/最小值/锁定期）
  - 暂停与恢复、设置奖励代币
  - 严格的角色控制（`ADMIN_ROLE/UPGRADE_ROLE/PAUSE_ROLE`）
- 升级能力：
  - UUPSUpgradeable + `_authorizeUpgrade`（受角色限制）

## 快速开始

### 环境
- Node/PNPM 可选（仅用于脚本工具链）
- Foundry（参考 `https://book.getfoundry.sh/`）
- 安装依赖（Soldeer 已完成 remapping）：

```bash
forge soldeer install @openzeppelin-contracts-upgradeable~5.4.0
forge soldeer install @openzeppelin-contracts~5.4.0
```

### 构建
```bash
forge build
```

### 运行本地链
```bash
anvil
```

### 单元测试
```bash
forge test -vv
# 或生成 gas 报告
forge test --gas-report
```

### 部署

使用脚本部署（UUPS via ERC1967Proxy）：

- 环境变量
  - `PRIVATE_KEY`: 部署私钥（十进制）
  - `ADMIN`: 若脚本未自动从私钥推导管理员，则提供该地址
  - 对 AwStake 还需：
    - `REWARD_START_BLOCK`, `REWARD_END_BLOCK`, `REWARD_PER_BLOCK`
    - 可选 `REWARD_TOKEN`（奖励代币地址）

- 部署 AwToken
```bash
forge script script/DeployAwToken.s.sol:DeployAwToken \
  --rpc-url <RPC> --broadcast
```

- 部署 AwStake
```bash
forge script script/DeployAwStake.s.sol:DeployAwStake \
  --rpc-url <RPC> --broadcast
```

部署流程说明：脚本先部署实现合约，再部署 `ERC1967Proxy` 并携带 `initialize` 数据（标准 UUPS 模式）。

### 升级

- 由具备 `UPGRADE_ROLE/ADMIN_ROLE` 的地址对代理调用 `upgradeToAndCall(newImpl, data)`
- 建议使用 OpenZeppelin Upgrades 工具进行存储布局检查与流程规范化

## Gas 分析与优化建议

生成报告：
```bash
forge test --gas-report
```
主要热点：`addStakePool / deposit / claim / unstake / updateStakePoolReward / withdraw`

建议（已部分落地）：
- 使用 Solidity 0.8+ 内置溢出检查替代 `Math.try*`，并在安全场景用 `unchecked`
- 提现请求结构建议改为队列游标，避免数组整体搬移（O(n)→O(1)）
- 合并/打包布尔开关与小整数，提升 slot packing，减少 SSTORE
- 仅当值变化时才执行 SSTORE 与事件发射
- 循环中缓存长度、`unchecked` 自增
- 按需保留 `SafeERC20`（自家标准代币可直传以省 gas）

## 事件与日志调试

在测试中提供事件打印示例（单行 `字段名:字段值`），便于调试与审计：
- `test_print_all_events`
- `test_print_event_logs_reward_update`

## 开发规范

- 使用 Foundry + OpenZeppelin Upgradeable 模块
- 遵循 UUPS 升级规范：实现 `_authorizeUpgrade` 并限制角色
- 单测覆盖关键路径与边界场景（多用户比例、奖励窗口边界、暂停/恢复等）
- 提交前运行构建与测试，必要时附带 gas 报告

## 常用命令

```bash
# 构建
forge build

# 测试（含日志）
forge test -vv

# Gas 报告
forge test --gas-report

# 本地链
anvil

# 部署示例
forge script script/DeployAwToken.s.sol:DeployAwToken --rpc-url <RPC> --broadcast
forge script script/DeployAwStake.s.sol:DeployAwStake --rpc-url <RPC> --broadcast
```
