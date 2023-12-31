// SPDX-License-Identifier: GNU-GPL v3.0 or later

pragma solidity ^0.8.19;

import "./Revest_base.sol";

/**
 * @title Revest_721
 * @author 0xTraub
 */
contract Revest_721 is Revest_base {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for address;
    using ERC165Checker for address;
    using FixedPointMathLib for uint256;
    using SafeCast for uint256;

    /**
     * @dev Primary constructor to create the Revest controller contract
     */
    constructor(address weth, address _tokenVault, address _metadataHandler, address govController)
        Revest_base(weth, _tokenVault, _metadataHandler, govController)
    {}

    /**
     * @dev creates a single time-locked NFT with <quantity> number of copies with <amount> of <asset> stored for each copy
     * asset - the address of the underlying ERC20 token for this bond
     * amount - the amount to store per NFT if multiple NFTs of this variety are being created
     * unlockTime - the timestamp at which this will unlock
     * quantity – the number of FNFTs to create with this operation
     */
    function _mintTimeLock(
        uint256 endTime,
        address[] memory recipients,
        uint256[] memory quantities,
        uint256 depositAmount,
        IRevest.FNFTConfig memory fnftConfig,
        bool usePermit2,
        bool isStream
    ) internal override returns (uint fnftId, bytes32 lockId) {
        require(fnftConfig.handler.supportsInterface(ERC721_INTERFACE_ID), "E001");

        //Each NFT for a handler as an identifier, so that you can mint multiple fnfts to the same nft
        fnftConfig.nonce = numfnfts[fnftConfig.handler][fnftConfig.fnftId]++;

        // Get or create lock based on time, assign lock to ID
        {
            fnftId = uint(keccak256(abi.encode(fnftConfig.fnftId, fnftConfig.handler, fnftConfig.nonce)));

            lockId = ILockManager(fnftConfig.lockManager).createLock(bytes32(fnftId), abi.encode(endTime));
        }

        //Stack Too Deep Fixer
        doMint(MintParameters(endTime, recipients, quantities, depositAmount, fnftId, fnftConfig, usePermit2));

        emit FNFTTimeLockMinted(fnftConfig.asset, msg.sender, fnftConfig.fnftId, endTime, quantities, fnftConfig);
    }

    function _mintAddressLock(
        bytes memory arguments,
        address[] memory recipients,
        uint256[] memory quantities,
        uint256 depositAmount,
        IRevest.FNFTConfig memory fnftConfig,
        bool usePermit2
    ) internal override returns (uint fnftId, bytes32 lockId) {
        require(fnftConfig.handler.supportsInterface(ERC721_INTERFACE_ID), "E001");

        //Each NFT for a handler as an identifier, so that you can mint multiple fnfts to the same nft
        fnftConfig.nonce = numfnfts[fnftConfig.handler][fnftConfig.fnftId]++;

        {
            fnftId = uint(keccak256(abi.encode(fnftConfig.fnftId, fnftConfig.handler, fnftConfig.nonce)));

            lockId = ILockManager(fnftConfig.lockManager).createLock(bytes32(fnftId), arguments);
        }

        //Stack Too Deep Fixer
        doMint(MintParameters(0, recipients, quantities, depositAmount, fnftId, fnftConfig, usePermit2));

        emit FNFTAddressLockMinted(fnftConfig.asset, msg.sender, fnftId, quantities, fnftConfig);
    }

    function withdrawFNFT(uint salt, uint256) external override nonReentrant {
        IRevest.FNFTConfig memory fnft = fnfts[salt];

        address currentOwner = IERC721(fnft.handler).ownerOf(fnft.fnftId);
        require(msg.sender == currentOwner, "E023");

        bytes32 lockId = keccak256(abi.encode(salt, address(this)));

        ILockManager(fnft.lockManager).unlockFNFT(lockId, fnft.fnftId);

        withdrawToken(salt, fnft.fnftId, currentOwner);

        emit FNFTWithdrawn(currentOwner, fnft.fnftId, 1);
    }

    function extendFNFTMaturity(uint salt, uint256 endTime) external override nonReentrant {
        IRevest.FNFTConfig storage fnft = fnfts[salt];
        uint256 fnftId = fnft.fnftId;
        address handler = fnft.handler;

        //Require that the new maturity is in the future
        require(endTime > block.timestamp, "E015");

        //Only the NFT owner can extend the lock on the NFT
        require(IERC721(handler).ownerOf(fnftId) == msg.sender, "E023");

        ILockManager manager = ILockManager(fnft.lockManager);

        // If it can't have its maturity extended, revert
        // Will also return false on non-time lock locks
        require(fnft.maturityExtension && manager.lockType() == ILockManager.LockType.TimeLock, "E009");

        bytes32 lockId = fnftIdToLockId(salt);

        // If desired maturity is below existing date or already unlocked, reject operation
        ILockManager.Lock memory lockParam = manager.getLock(lockId);

        require(!lockParam.unlocked && lockParam.timeLockExpiry > block.timestamp, "E007");

        require(lockParam.timeLockExpiry < endTime, "E010");

        //Just pick a salt, it doesn't matter as long as it's unique
        manager.extendLockMaturity(bytes32(salt), abi.encode(endTime));

        emit FNFTMaturityExtended(lockId, msg.sender, fnftId, endTime);
    }

    /**
     * Amount will be per FNFT. So total ERC20s needed is amount * quantity.
     * We don't charge an ETH fee on depositAdditional, but do take the erc20 percentage.
     */
    function _depositAdditionalToFNFT(uint salt, uint256 amount, bool usePermit2)
        internal
        override
        returns (uint256)
    {
        IRevest.FNFTConfig storage fnft = fnfts[salt];
        uint256 fnftId = fnft.fnftId;

        //If the handler is an NFT then supply is 1

        bytes32 walletSalt = keccak256(abi.encode(fnft.fnftId, fnft.handler));
        address smartWallet = tokenVault.getAddress(walletSalt, address(this));

        address depositAsset = fnft.asset;

        //Underlying is ETH, deposit ETH by wrapping to WETH
        if (msg.value != 0 && fnft.asset == ETH_ADDRESS) {
            require(msg.value == amount, "E027");

            IWETH(WETH).deposit{value: msg.value}();

            ERC20(WETH).safeTransfer(smartWallet, amount);

            return amount;
        }
        //Underlying is ETH, user wants to deposit WETH, no wrapping required
        else if (msg.value == 0 && fnft.asset == ETH_ADDRESS) {
            depositAsset = WETH;
        }

        if (usePermit2) {
            PERMIT2.transferFrom(msg.sender, smartWallet, amount.toUint160(), depositAsset);
        } else {
            ERC20(depositAsset).safeTransferFrom(msg.sender, smartWallet, amount);
        }

        emit FNFTAddionalDeposited(msg.sender, fnftId, 1, amount);

        return amount;
    }

    //
    // INTERNAL FUNCTIONS
    //
    function doMint(IRevest.MintParameters memory params) internal {
        //fnftSalt is the identifier for FNFT itself associated with the NFT, you need it to withdraw

        /*
        * Wallet salt is used to generate the wallet. All FNFTs attached to a given NFT have their tokens stored in the same address.
        * This is because the NFT is the identifier for the vault, and the FNFT is the identifier for the token within the vault.
        * and since every FNFT has a difference nonce we need to remove it from the salt to be able to generate the same address
        */
        bytes32 WalletSalt = keccak256(abi.encode(params.fnftConfig.fnftId, params.fnftConfig.handler));

        // Create the FNFT and update accounting within TokenVault
        // Now, we move the funds to token vault from the message sender
        address smartWallet = tokenVault.getAddress(WalletSalt, address(this));

        if (msg.value != 0) {
            params.fnftConfig.asset = ETH_ADDRESS;
            IWETH(WETH).deposit{value: msg.value}(); //Convert it to WETH and send it back to this
            IWETH(WETH).transfer(smartWallet, msg.value); //Transfer it to the smart wallet
        } else if (params.usePermit2) {
            PERMIT2.transferFrom(msg.sender, smartWallet, (params.depositAmount).toUint160(), params.fnftConfig.asset);
        } else {
            ERC20(params.fnftConfig.asset).safeTransferFrom(msg.sender, smartWallet, params.depositAmount);
        }

        fnfts[params.fnftId] = params.fnftConfig;

        emit CreateFNFT(params.fnftId, msg.sender);
    }

    function withdrawToken(uint salt, uint256 fnftId, address user) internal {
        // If the FNFT is an old one, this just assigns to zero-value
        IRevest.FNFTConfig memory fnft = fnfts[salt];
        uint256 amountToWithdraw;

        //When the user deposits Eth it stores the asset as the all E's address but actual WETH is kept in the vault
        address transferAsset = fnft.asset == ETH_ADDRESS ? WETH : fnft.asset;

        bytes32 walletSalt = keccak256(abi.encode(fnftId, fnft.handler));

        address smartWallAdd = tokenVault.getAddress(walletSalt, address(this));

        amountToWithdraw = IERC20(transferAsset).balanceOf(smartWallAdd);

        // Deploy the smart wallet object
        bytes memory delegateCallData = abi.encode(transferAsset, amountToWithdraw, address(this));
        tokenVault.invokeSmartWallet(walletSalt, WITHDRAW_SELECTOR, delegateCallData);

        if (fnft.asset == ETH_ADDRESS) {
            IWETH(WETH).withdraw(amountToWithdraw);
            user.safeTransferETH(amountToWithdraw);
        } else {
            ERC20(fnft.asset).safeTransfer(user, amountToWithdraw);
        }

        emit WithdrawERC20(transferAsset, user, fnftId, amountToWithdraw, smartWallAdd);

        emit RedeemFNFT(salt, user);
    }


    function getValue(uint fnftId) external view virtual returns (uint256) {
        IRevest.FNFTConfig memory fnft = fnfts[fnftId];

        address asset = fnft.asset == ETH_ADDRESS ? WETH : fnft.asset;

        return IERC20(asset).balanceOf(getAddressForFNFT(fnftId));
    }

    function getSaltFromId(address handler, uint256 fnftId, uint256 nonce) public pure returns (uint) {
        return uint(keccak256(abi.encode(fnftId, handler, nonce)));
    }

    function fnftIdToLockId(uint256 fnftId) public view returns (bytes32 lockId) {
        return keccak256(abi.encode(bytes32(fnftId), address(this)));
    }

    //Takes in an FNFT Salt and generates a wallet salt from it
    function getAddressForFNFT(uint salt) public view virtual returns (address smartWallet) {
        IRevest.FNFTConfig memory fnft = fnfts[salt];

        bytes32 walletSalt = keccak256(abi.encode(fnft.fnftId, fnft.handler));

        smartWallet = tokenVault.getAddress(walletSalt, address(this));
    }
}
