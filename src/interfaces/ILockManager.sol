// SPDX-License-Identifier: GNU-GPL v3.0 or later

pragma solidity ^0.8.19;

import "./IRevest.sol";

interface ILockManager {
    enum LockType {
        DEFAULT,
        TimeLock,
        AddressLock
    }

    struct Lock {
        bool unlocked;
        uint96 timeLockExpiry;
        uint96 creationTime;
    }

    function createLock(bytes32 fnftId, bytes calldata args) external returns (bytes32);

    function getLock(bytes32 lockId) external view returns (Lock memory);

    function lockType() external view returns (LockType);

    function unlockFNFT(bytes32 salt, uint256 fnftId) external;

    function getLockMaturity(bytes32 salt, uint256 fnftId) external view returns (bool);

    function lockExists(bytes32 lockSalt) external view returns (bool);

    function extendLockMaturity(bytes32 salt, bytes calldata args) external;

    function getMetadata(bytes32 lockId) external view returns (string memory);
    function lockDescription(bytes32 lockId) external view returns (string memory);
    function getLockCreationTime(bytes32 lockId) external view returns (uint96);
    function getLockEndTime(bytes32 lockId) external view returns (uint96);
}
