// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20Upgradeable } from '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { UUPSUpgradeable } from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import { OwnableUpgradeable } from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import { AccessControlUpgradeable } from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';

/**
 * @title AwToken
 * @author AwStake
 * @notice ERC20 token for AwStake
 */
contract AwToken is Initializable, ERC20Upgradeable, UUPSUpgradeable, OwnableUpgradeable, AccessControlUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256('ADMIN_ROLE');
    bytes32 public constant MINTER_ROLE = keccak256('MINTER_ROLE');
    bytes32 public constant BURNER_ROLE = keccak256('BURNER_ROLE');

    /**
     * @notice Initialize the contract
     * @param __initAdmin The address to initialize the contract with
     */
    function initialize(address __initAdmin) public initializer {
        __ERC20_init('AwToken', 'AW');
        __UUPSUpgradeable_init();
        __Ownable_init(__initAdmin);
        __AccessControl_init();
        _grantRole(ADMIN_ROLE, __initAdmin);
        _grantRole(MINTER_ROLE, __initAdmin);
        _grantRole(BURNER_ROLE, __initAdmin);
    }

    /**
     * @notice Mint tokens to an address
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from an address
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint amount) public onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    /**
     * @notice Authorize an upgrade
     * @param newImplementation The new implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) { }
}
