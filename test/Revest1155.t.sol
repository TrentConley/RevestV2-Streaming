// SPDX-License-Identifier: GNU-GPL v3.0 or later

pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "src/Revest_1155.sol";
import "src/TokenVault.sol";
import "src/LockManager_Timelock.sol";
import "src/LockManager_Addresslock.sol";

import "src/FNFTHandler.sol";
import "src/MetadataHandler.sol";

import "src/lib/PermitHash.sol";
import "src/interfaces/IAllowanceTransfer.sol";
import "src/lib/EIP712.sol";

import "@solmate/utils/SafeTransferLib.sol";

contract Revest1155Tests is Test {
    using PermitHash for IAllowanceTransfer.PermitBatch;
    using SafeTransferLib for ERC20;

    Revest_1155 public immutable revest;
    TokenVault public immutable vault;
    LockManager_Timelock public immutable lockManager_timelock;
    LockManager_Addresslock public immutable lockManager_addresslock;

    FNFTHandler public immutable fnftHandler;
    MetadataHandler public immutable metadataHandler;

    address public constant govController = address(0xdead);

    uint256 PRIVATE_KEY = 0x7ad412da56ca959b758cf66340119a7e6e182e206ceb79735310b04142f3ee3d;//Useful for EIP-712 Testing
    address alice = vm.rememberKey(PRIVATE_KEY);
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    ERC20 WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bytes signature;
    IAllowanceTransfer.PermitBatch permit;

    string baseURI = "https://ipfs.io/ipfs/";

    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);


    constructor() {
        vm.createSelectFork("mainnet");

        vault = new TokenVault();
        metadataHandler = new MetadataHandler(baseURI);
        revest = new Revest_1155("", address(WETH), address(vault), address(metadataHandler), govController);

        lockManager_timelock = new LockManager_Timelock();
        lockManager_addresslock = new LockManager_Addresslock();

        fnftHandler = FNFTHandler(address(revest.fnftHandler()));

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(carol, "carol");
        vm.label(address(revest), "revest");
        vm.label(address(vault), "tokenVault");
        vm.label(address(fnftHandler), "fnftHandler");
        vm.label(address(lockManager_timelock), "lockManager_timelock");
        vm.label(address(lockManager_addresslock), "lockManager_addresslock");
        vm.label(address(USDC), "USDC");
        vm.label(address(WETH), "WETH");

        deal(address(WETH), alice, type(uint256).max);
        deal(address(USDC), alice, type(uint256).max);
        deal(alice, type(uint256).max);

        startHoax(alice, alice);

        USDC.safeApprove(address(revest), type(uint256).max);
        USDC.safeApprove(PERMIT2, type(uint256).max);

        WETH.safeApprove(address(revest), type(uint256).max);
        WETH.safeApprove(PERMIT2, type(uint256).max);
    }

    function setUp() public {
        // --- CALCULATING THE SIGNATURE FOR PERMIT2 AHEAD OF TIME PREVENTS STACK TOO DEEP --- DO NOT REMOVE
        IAllowanceTransfer.PermitDetails memory details = IAllowanceTransfer.PermitDetails({
            token: address(USDC),
            amount: type(uint160).max,
            expiration: 0, //Only valid for length of the tx
            nonce: uint48(0)
        });

        permit.spender = address(revest);
        permit.sigDeadline = block.timestamp + 1 weeks;
        permit.details.push(details);

        {
            bytes32 DOMAIN_SEPARATOR = EIP712(PERMIT2).DOMAIN_SEPARATOR();
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, permit.hash()));

            //Sign the permit info
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);
            signature = abi.encodePacked(r, s, v);
        }
    }

    function testMintTimeLockToAlice(uint8 supply, uint256 amount) public {
        vm.assume(supply % 2 == 0 && supply >= 2);
        vm.assume(amount >= 1e6 && amount < 1e12);

        uint256 preBal = USDC.balanceOf(alice);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory supplies = new uint[](1);
        supplies[0] = supply;

        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(USDC),
            lockManager: address(lockManager_timelock),
            nonce: 0,
            fnftId: 0,
            maturityExtension: false
        });

        config.handler = address(fnftHandler);

        uint256 currentTime = block.timestamp;
        (uint id, bytes32 lockId) =
            revest.mintTimeLock(block.timestamp + 1 weeks, recipients, supplies, amount, config);

        assertEq(revest.fnftIdToLockId(id), lockId, "lockId was not calculated correctly");

        vm.expectRevert(bytes("E015"));
        lockManager_timelock.createLock(keccak256(abi.encode("0xdead")), abi.encode(block.timestamp - 1 weeks));

        address walletAddr = revest.getAddressForFNFT(id);

        //Check Minting was successful
        {
            //Funds were deducted from alice
            uint256 postBal = USDC.balanceOf(alice);

            assertEq(postBal, preBal - (supply * amount), "balance did not decrease by expected amount");

            //Funds were moved into the smart wallet
            assertEq(USDC.balanceOf(walletAddr), supply * amount, "vault balance did not increase by expected amount");

            //FNFTs were minted to alice
            assertEq(fnftHandler.balanceOf(alice, id), supply, "alice did not receive expected amount of FNFTs");
            assertEq(fnftHandler.totalSupply(id), supply, "total supply of FNFTs did not increase by expected amount");

            //Lock was created
            ILockManager.Lock memory lock = lockManager_timelock.getLock(lockId);
            assertEq(
                uint256(lockManager_timelock.lockType()),
                uint256(ILockManager.LockType.TimeLock),
                "lock type is not TimeLock"
            );

            assertFalse(lock.timeLockExpiry == 0, "timeLock Expiry should not be zero");
            assertEq(currentTime + 1 weeks, lock.timeLockExpiry, "lock expiry is not expected value");
            assertEq(lock.unlocked, false);
        }

        //Transfer the FNFT from Alice -> Bob
        {
            fnftHandler.safeTransferFrom(alice, bob, id, supply, "");
            assertEq(fnftHandler.balanceOf(alice, id), 0, "alice did not lose expected amount of FNFTs");
            assertEq(fnftHandler.balanceOf(bob, id), supply, "bob did not receive expected amount of FNFTs");
        }



        changePrank(bob);
        vm.expectRevert(bytes("E006"));
        revest.unlockFNFT(id);

        assertFalse(lockManager_timelock.getLockMaturity(lockId, id));

        vm.expectRevert(bytes("E016"));
        lockManager_timelock.unlockFNFT(keccak256(abi.encode("0xdead")), 0);

        skip(1 weeks + 1 seconds);
        assertFalse(!lockManager_timelock.getLockMaturity(lockId, id));

        revest.unlockFNFT(id);

        assertEq(lockManager_timelock.getTimeRemaining(lockId, 0), 0, "time remaining should be zero");

        console.log("------------------");

        revest.withdrawFNFT(id, supply);

        vm.expectRevert(bytes("E028"));
        revest.implementSmartWalletWithdrawal("");

        (bool success, ) = address(revest).delegatecall(abi.encodeWithSelector(bytes4(keccak256("implementSmartWalletWithdrawal(bytes)")), ""));
        assertFalse(success);

        assertEq(fnftHandler.balanceOf(bob, id), 0, "bob did not lose expected amount of FNFTs"); //All FNFTs were burned
        assertEq(USDC.balanceOf(bob), supply * amount, "bob did not receive expected amount of USDC"); //All funds were returned to bob
        assertEq(fnftHandler.totalSupply(id), 0, "total supply of FNFTs did not decrease by expected amount"); //Total supply of FNFTs was decreased
        assertEq(USDC.balanceOf(walletAddr), 0, "vault balance did not decrease by expected amount"); //All funds were removed from SmartWallet

        assertEq(revest.getAsset(id), address(USDC), "asset was not set correctly");
        assertEq(revest.getValue(id), 0, "value was not set correctly");

        supplies[0] = 0;
        vm.expectRevert(bytes("E012"));
        revest.mintTimeLock(block.timestamp + 1 weeks, recipients, supplies, amount, config);

        supplies = new uint[](2);   
        vm.expectRevert(bytes("E011"));
        revest.mintTimeLock(block.timestamp + 1 weeks, recipients, supplies, amount, config);
    }

    function testBatchMintTimeLock(uint8 supply, uint256 amount) public {
        vm.assume(supply % 2 == 0 && supply >= 2);
        vm.assume(amount >= 1e6 && amount <= 1e12);

        uint256 preBal = USDC.balanceOf(alice);

        //Mint half to bob and half to alice
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;

        uint256[] memory amounts = new uint[](2);
        amounts[0] = supply / 2;
        amounts[1] = supply / 2;

        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(USDC),
            lockManager: address(lockManager_timelock),
            nonce: 0,
            fnftId: 0,
            maturityExtension: false
        });

        config.handler = address(fnftHandler);

        (uint id,) = revest.mintTimeLock(block.timestamp + 1 weeks, recipients, amounts, amount, config);

        address walletAddr = revest.getAddressForFNFT(id);

        {
            //Funds were deducted from alice
            uint256 postBal = USDC.balanceOf(alice);
            assertEq(postBal, preBal - (supply * amount), "balance did not decrease by expected amount");

            //Funds were moved into the smart wallet
            assertEq(USDC.balanceOf(walletAddr), supply * amount, "vault balance did not increase by expected amount");

            //FNFTs were minted to alice and Bob
            assertEq(fnftHandler.balanceOf(alice, id), supply / 2, "alice did not receive expected amount of FNFTs");
            assertEq(fnftHandler.balanceOf(bob, id), supply / 2, "alice did not receive expected amount of FNFTs");
            assertEq(fnftHandler.totalSupply(id), supply, "total supply of FNFTs did not increase by expected amount");

            //Lock was created
            ILockManager.Lock memory lock = revest.getLock(id);
            assertEq(
                uint256(lockManager_timelock.lockType()),
                uint256(ILockManager.LockType.TimeLock),
                "lock type is not TimeLock"
            );
            assertEq(lock.timeLockExpiry, block.timestamp + 1 weeks, "lock expiry is not expected value");
            assertEq(lock.unlocked, false);
        }


        vm.expectRevert(abi.encodeWithSelector(ERC1155InsufficientBalance.selector, alice, supply / 2, supply, id));
        revest.withdrawFNFT(id, supply); //Should Revert for trying to burn more than balance

        vm.expectRevert(bytes("E006"));
        revest.withdrawFNFT(id, supply / 2); //Should revert because lock is not expired

        vm.expectRevert(bytes("E003"));
        revest.withdrawFNFT(type(uint).max, supply / 2); //Should revert because lock does not exist

        skip(1 weeks);

        revest.withdrawFNFT(id, supply / 2); //Should execute correctly

        assertEq(
            USDC.balanceOf(alice), preBal - ((supply * amount) / 2), "alice did not receive expected amount of USDC"
        );
        assertEq(fnftHandler.balanceOf(alice, id), 0, "alice did not receive expected amount of FNFTs");
        assertEq(fnftHandler.totalSupply(id), supply / 2, "total supply of FNFTs did not decrease by expected amount");
        assertEq(USDC.balanceOf(walletAddr), (supply * amount) / 2, "vault balance did not decrease by expected amount");
        assertEq(
            fnftHandler.balanceOf(bob, id), fnftHandler.totalSupply(id), "expected and actual FNFT supply do not match"
        );
    }

    function testMintAddressLock(uint8 supply, uint256 amount) public {
        vm.assume(supply != 0);
        vm.assume(amount >= 1e6 && amount <= 1e12);

        uint256 preBal = USDC.balanceOf(alice);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory amounts = new uint[](1);
        amounts[0] = supply;


        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(0),
            asset: address(USDC),
            fnftId: 0,
            lockManager: address(lockManager_addresslock),
            nonce: 0,
            maturityExtension: false
        });

        config.handler = address(fnftHandler);
        (uint id, bytes32 lockId) = revest.mintAddressLock("", recipients, amounts, amount, config);

        address walletAddr = revest.getAddressForFNFT(id);

        //Lock was created
        ILockManager.Lock memory lock = lockManager_addresslock.getLock(lockId);
        assertEq(
            uint256(lockManager_addresslock.lockType()),
            uint256(ILockManager.LockType.AddressLock),
            "lock type is not AddressLock"
        );
        assertEq(lock.unlocked, false);
        assertEq(lock.creationTime, block.timestamp, "lock creation time is not expected value");

        if (block.timestamp % 2 == 0) skip(1 seconds);

        assertFalse(lockManager_addresslock.getLockMaturity(lockId, id));

        vm.expectRevert(bytes("E006"));
        revest.withdrawFNFT(id, supply); //Should revert because lock has not expired

        skip(1 seconds);
        assertFalse(!lockManager_addresslock.getLockMaturity(lockId, id));
        revest.withdrawFNFT(id, supply);

        //Check that the lock was unlocked and all funds returned to alice
        assertEq(fnftHandler.balanceOf(alice, id), 0, "alice did not lose expected amount of FNFTs"); //All FNFTs were burned
        assertEq(USDC.balanceOf(alice), preBal, "alice did not receive expected amount of USDC"); //All funds were returned to bob
        assertEq(fnftHandler.totalSupply(id), 0, "total supply of FNFTs did not decrease by expected amount"); //Total supply of FNFTs was decreased
        assertEq(USDC.balanceOf(walletAddr), 0, "vault balance did not decrease by expected amount"); //All funds were removed from SmartWallet
    }

    function testDepositAdditionalToToFNFT(uint8 supply, uint256 amount, uint256 additionalDepositAmount) public {
        vm.assume(supply % 2 == 0 && supply >= 2);
        vm.assume(amount >= 1e6 && amount <= 1e20);
        vm.assume(additionalDepositAmount >= 1e6 && additionalDepositAmount <= 1e20);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory amounts = new uint[](1);
        amounts[0] = supply;

        uint256 preBal = USDC.balanceOf(alice);


        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(0),
            asset: address(USDC),
            lockManager: address(lockManager_timelock),
            fnftId: 0,
            nonce: 0,
            maturityExtension: false
        });

        (uint id,) = revest.mintTimeLock(block.timestamp + 1 weeks, recipients, amounts, amount, config);

        address walletAddr = revest.getAddressForFNFT(id);
        uint256 balanceBefore = USDC.balanceOf(walletAddr);
        uint256 aliceBalanceBeforeAdditionalDeposit = USDC.balanceOf(alice);

        uint256 tempSupply = supply / 2;
        {
            vm.expectRevert(bytes("E003"));
            revest.depositAdditionalToFNFT(type(uint).max, additionalDepositAmount);

            revest.depositAdditionalToFNFT(id, additionalDepositAmount);
            assertEq(
                USDC.balanceOf(walletAddr),
                balanceBefore + additionalDepositAmount * supply,
                "vault balance did not increase by expected amount"
            );
            assertEq(
                USDC.balanceOf(alice),
                aliceBalanceBeforeAdditionalDeposit - (additionalDepositAmount * supply),
                "alice balance did not decrease by expected amount"
            );

            assertEq(
                USDC.balanceOf(alice),
                preBal - (supply * (amount + additionalDepositAmount)),
                "alice balance did not decrease by expected amount"
            );

            assertEq(revest.getValue(id), amount + additionalDepositAmount, "deposit amount was not updated");

            skip(1 weeks);

            fnftHandler.safeTransferFrom(alice, bob, id, tempSupply, "");

            changePrank(bob);
            revest.withdrawFNFT(id, tempSupply);
            destroyAccount(walletAddr, address(this));
        }

        assertEq(
            USDC.balanceOf(bob), revest.getValue(id) * tempSupply, "alice balance did not increase by expected amount"
        );

        assertEq(
            USDC.balanceOf(bob), tempSupply * (amount + additionalDepositAmount), "full amount not transfered to bob"
        );

        changePrank(alice);
        revest.withdrawFNFT(id, tempSupply);

        assertEq(
            USDC.balanceOf(alice), preBal - USDC.balanceOf(bob), "alice balance did not increase by expected amount"
        );
    }

    function testmintTimeLockAndExtendMaturity(uint8 supply, uint256 amount) public {
        vm.assume(supply % 2 == 0 && supply >= 2);
        vm.assume(amount >= 1e6 && amount <= 1e20);

        uint256 preBal = USDC.balanceOf(alice);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory amounts = new uint[](1);
        amounts[0] = supply;


        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(USDC),
            lockManager: address(lockManager_timelock),
            fnftId: 0,
            nonce: 0,
            maturityExtension: true
        });

        (uint id, bytes32 lockId) =
            revest.mintTimeLock(block.timestamp + 1 weeks, recipients, amounts, amount, config);
        address walletAddr;

        {
            walletAddr = revest.getAddressForFNFT(id);
            assertEq(USDC.balanceOf(walletAddr), amount * supply, "vault balance did not increase by expected amount");

            fnftHandler.safeTransferFrom(alice, bob, id, 1, "");
            vm.expectRevert(bytes("E008")); //Revert because you don't own the entire supply of the FNFT
            revest.extendFNFTMaturity(id, block.timestamp + 2 weeks); //Extend a week beyond the current endDate

            vm.expectRevert(bytes("E003")); //Revert because FNFT doesn't exist
            revest.extendFNFTMaturity(type(uint).max, block.timestamp + 2 weeks); //Extend a week beyond the current endDate

            //Send it back to Alice so she can extend maturity
            changePrank(bob);
            fnftHandler.safeTransferFrom(bob, alice, id, 1, "");

            changePrank(alice);

            skip(2 weeks);
            vm.expectRevert(bytes("E015")); //Revert because new FNFT maturity date is in the past
            revest.extendFNFTMaturity(id, block.timestamp - 2 weeks);

            vm.expectRevert(bytes("E007")); //Revert because new FNFT maturity date has already passed
            revest.extendFNFTMaturity(id, block.timestamp + 2 weeks); //Extend a week beyond the current endDate

            rewind(2 weeks); //Go back 2 weeks to actually extend this time

            //Should revert because new unlockTime is not after current unlockTime
            vm.expectRevert(bytes("E010"));
            revest.extendFNFTMaturity(id, block.timestamp + 1 days);

            uint256 currTime = block.timestamp;
            revest.extendFNFTMaturity(id, block.timestamp + 2 weeks); //Extend a week beyond the current endDate

            uint256 newEndTime = lockManager_timelock.getLock(lockId).timeLockExpiry;
            assertEq(newEndTime, currTime + 2 weeks, "lock did not extend maturity by expected amount");

            skip(2 weeks);
            revest.withdrawFNFT(id, supply);

            assertEq(USDC.balanceOf(alice), preBal, "alice balance did not increase by expected amount");
        }

        //Same Test but should fail to extend maturity because maturityExtension is false
        config.maturityExtension = false;

        (id, lockId) = revest.mintTimeLock(block.timestamp + 1 weeks, recipients, amounts, amount, config);

        bytes32 lockSalt = revest.fnftIdToLockId(id);
        assertEq(lockManager_timelock.getTimeRemaining(lockSalt, 0), 1 weeks, "expected time not remaining");

        walletAddr = revest.getAddressForFNFT(id);
        assertEq(USDC.balanceOf(walletAddr), amount * supply, "vault balance did not increase by expected amount");

        vm.expectRevert(bytes("E009")); //Revert because FNFT is marked as non-extendable
        revest.extendFNFTMaturity(id, block.timestamp + 2 weeks); //Extend a week beyond the current endDate
    }

    function testMintFNFTWithEth(uint256 supply, uint256 amount) public {
        vm.assume(amount >= 1 ether && amount <= 100 ether);

        supply = bound(supply, 2, 1e6);
        // vm.assume(supply > 1 && supply <= 1e6);

        startHoax(alice, alice);

        uint256 preBal = alice.balance;

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory amounts = new uint[](1);
        amounts[0] = supply;


        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(0),
            lockManager: address(lockManager_timelock),
            fnftId: 0,
            nonce: 0,
            maturityExtension: true
        });

        (uint id,) =
            revest.mintTimeLock{value: amount * supply}(block.timestamp + 1 weeks, recipients, amounts, amount, config);

        address walletAddr = revest.getAddressForFNFT(id);
        assertEq(
            ERC20(WETH).balanceOf(walletAddr), amount * supply, "vault balance did not increase by expected amount"
        );

        assertEq(alice.balance, preBal - (supply * amount), "alice balance did not decrease by expected amountof ETH");
        IController.FNFTConfig memory storedConfig = revest.getFNFT(id);

        assertEq(storedConfig.asset, ETH_ADDRESS, "asset was not set to ETH");
        assertEq(revest.getValue(id), amount, "deposit amount was not set to amount");

        skip(1 weeks);
        revest.withdrawFNFT(id, supply);
        assertEq(alice.balance, preBal, "alice balance did not increase by expected amount of ETH");

        preBal = alice.balance;
        uint256 wethPreBal = WETH.balanceOf(alice);
        (id,) =
            revest.mintTimeLock{value: amount * supply}(block.timestamp + 1 weeks, recipients, amounts, amount, config);

        vm.expectRevert(bytes("E027"));
        revest.depositAdditionalToFNFT{value: 1 ether}(id, 1 ether);

        revest.depositAdditionalToFNFT{value: (1 ether * supply)}(id, 1 ether);
        revest.depositAdditionalToFNFT(id, 1 ether);

        assertEq(
            alice.balance,
            preBal - (supply * (amount + 1 ether)),
            "alice balance did not decrease by expected amount of ETH"
        );
        assertEq(
            WETH.balanceOf(alice),
            wethPreBal - (supply * (1 ether)),
            "alice balance did not decrease by expected amount of WETH"
        );

        storedConfig = revest.getFNFT(id);
        assertEq(storedConfig.asset, ETH_ADDRESS, "asset was not set to ETH");
        assertEq(revest.getValue(id), amount + 2 ether, "deposit amount was not set to amount");

        skip(1 weeks);

        revest.withdrawFNFT(id, supply);
        assertEq(alice.balance, preBal + (1 ether * supply), "alice balance did not increase by expected amount of ETH");
    }

    function testTransferFNFTWithSignature() public {
        startHoax(alice);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory amounts = new uint[](1);
        amounts[0] = 1;


        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(USDC),
            lockManager: address(lockManager_timelock),
            fnftId: 0,
            nonce: 0,
            maturityExtension: true
        });

        (uint id, ) = revest.mintTimeLock(block.timestamp + 1 weeks, recipients, amounts, 1e6, config);

        bytes32 SET_APPROVALFORALL_TYPEHASH = keccak256(
            "transferFromWithPermit(address owner,address operator, bool approved, uint id, uint amount, uint256 deadline, uint nonce, bytes data)"
        );

        bytes32 DOMAIN_SEPARATOR = fnftHandler.DOMAIN_SEPARATOR();

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        SET_APPROVALFORALL_TYPEHASH, alice, bob, true, id, 1, block.timestamp + 1 weeks, 0, bytes("")
                    )
                )
            )
        );

        //Sign the permit info
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);
        bytes memory transferSignature = abi.encodePacked(r, s, v);

        //The Permit info itself
        IFNFTHandler.permitApprovalInfo memory transferPermit = IFNFTHandler.permitApprovalInfo({
            owner: alice,
            operator: bob,
            id: id,
            amount: 1,
            deadline: block.timestamp + 1 weeks,
            data: bytes("")
        });

        skip(2 weeks);
        vm.expectRevert(bytes("ERC1155: signature expired"));
        fnftHandler.transferFromWithPermit(transferPermit, transferSignature);

        rewind(2 weeks);

        vm.expectRevert(bytes("E018"));
        fnftHandler.transferFromWithPermit(transferPermit, "0xdead");

        //Do the transfer
        fnftHandler.transferFromWithPermit(transferPermit, transferSignature);

        assertEq(fnftHandler.balanceOf(alice, id), 0, "alice still owns FNFT");
        assertEq(fnftHandler.balanceOf(bob, id), 1, "bob does not own FNFT");
        assertEq(fnftHandler.isApprovedForAll(alice, bob), true);
    }

    

    function testMintTimeLockWithPermit2(uint160 amount) public {
        vm.assume(amount >= 1e6 && amount <= 1e12);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory amounts = new uint[](1);
        amounts[0] = 1;

        bytes32 lockId;
        uint id;
        {
            IController.FNFTConfig memory config = IController.FNFTConfig({
                handler: address(fnftHandler),
                asset: address(USDC),
                lockManager: address(lockManager_timelock),
                fnftId: 0,
                nonce: 0,
                maturityExtension: true
            });

            vm.expectRevert(bytes("E024"));
            revest.mintTimeLockWithPermit(
                block.timestamp + 1 weeks, recipients, amounts, uint256(amount), config, permit, ""
            );

            (id, lockId) = revest.mintTimeLockWithPermit(
                block.timestamp + 1 weeks, recipients, amounts, uint256(amount), config, permit, signature
            );
        }

        assertEq(fnftHandler.balanceOf(alice, id), 1, "FNFT not minted");
        assertEq(USDC.balanceOf(revest.getAddressForFNFT(id)), amount, "USDC not deposited into vault");

        //Test that Lock was created
        ILockManager.Lock memory lock = lockManager_timelock.getLock(lockId);
        assertEq(
            uint256(lockManager_timelock.lockType()),
            uint256(ILockManager.LockType.TimeLock),
            "lock type is not TimeLock"
        );
        assertEq(lock.timeLockExpiry, block.timestamp + 1 weeks, "lock expiry is not expected value");
        assertEq(lock.unlocked, false);
    }

    function testMintAddressLockWithPermit2(uint160 amount, uint8 supply) public {
        vm.assume(amount >= 1e6 && amount <= 1e12);
        vm.assume(supply >= 1);

        uint256 preBal = USDC.balanceOf(alice);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory amounts = new uint[](1);
        amounts[0] = supply;


        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(USDC),
            fnftId: 0,
            lockManager: address(lockManager_addresslock),
            nonce: 0,
            maturityExtension: false
        });

        vm.expectRevert(bytes("E024"));
        revest.mintAddressLockWithPermit("", recipients, amounts, uint256(amount), config, permit, "");

        (uint id, bytes32 lockId) =
            revest.mintAddressLockWithPermit("", recipients, amounts, uint256(amount), config, permit, signature);

        address walletAddr = revest.getAddressForFNFT(id);

        //Lock was created
        ILockManager.Lock memory lock = lockManager_addresslock.getLock(lockId);
        assertEq(
            uint256(lockManager_addresslock.lockType()),
            uint256(ILockManager.LockType.AddressLock),
            "lock type is not AddressLock"
        );
        assertEq(lock.unlocked, false);
        assertEq(lock.creationTime, block.timestamp, "lock creation time is not expected value");

        if (block.timestamp % 2 == 0) skip(1 seconds);

        vm.expectRevert(bytes("E006"));
        revest.withdrawFNFT(id, supply); //Should revert because lock has not expired

        skip(1 seconds);
        revest.withdrawFNFT(id, supply);

        //Check that the lock was unlocked and all funds returned to alice
        assertEq(fnftHandler.balanceOf(alice, id), 0, "alice did not lose expected amount of FNFTs"); //All FNFTs were burned
        assertEq(USDC.balanceOf(alice), preBal, "alice did not receive expected amount of USDC"); //All funds were returned to bob
        assertEq(fnftHandler.totalSupply(id), 0, "total supply of FNFTs did not decrease by expected amount"); //Total supply of FNFTs was decreased
        assertEq(USDC.balanceOf(walletAddr), 0, "vault balance did not decrease by expected amount"); //All funds were removed from SmartWallet
    }

    function testDepositAdditionalToToFNFTWithPermit2(uint8 supply, uint256 amount, uint256 additionalDepositAmount)
        public
    {
        vm.assume(supply % 2 == 0 && supply >= 2);
        vm.assume(amount >= 1e6 && amount <= 1e20);
        vm.assume(additionalDepositAmount >= 1e6 && additionalDepositAmount <= 1e20);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory amounts = new uint[](1);
        amounts[0] = supply;

        uint256 preBal = USDC.balanceOf(alice);

        uint id;
        {
            IController.FNFTConfig memory config = IController.FNFTConfig({
                handler: address(fnftHandler),
                asset: address(USDC),
                fnftId: 0,
                lockManager: address(lockManager_timelock),
                nonce: 0,
                maturityExtension: false
            });

            (id,) = revest.mintTimeLock(block.timestamp + 1 weeks, recipients, amounts, amount, config);
        }

        address walletAddr = revest.getAddressForFNFT(id);
        uint256 balanceBefore = USDC.balanceOf(walletAddr);
        uint256 aliceBalanceBeforeAdditionalDeposit = USDC.balanceOf(alice);

        vm.expectRevert(bytes("E024"));
        revest.depositAdditionalToFNFTWithPermit(id, additionalDepositAmount, permit, "");

        revest.depositAdditionalToFNFTWithPermit(id, additionalDepositAmount, permit, signature);

        {
            assertEq(
                USDC.balanceOf(walletAddr),
                balanceBefore + (additionalDepositAmount * supply),
                "vault balance did not increase by expected amount"
            );

            assertEq(
                USDC.balanceOf(alice),
                aliceBalanceBeforeAdditionalDeposit - (additionalDepositAmount * supply),
                "alice balance did not decrease by expected amount"
            );

            assertEq(
                USDC.balanceOf(alice),
                preBal - (supply * (amount + additionalDepositAmount)),
                "alice balance did not decrease by expected amount"
            );

            assertEq(revest.getValue(id), amount + additionalDepositAmount, "deposit amount was not updated");
        }

        uint256 tempSupply = supply / 2;
        skip(1 weeks);
        fnftHandler.safeTransferFrom(alice, bob, id, tempSupply, "");

        changePrank(bob);
        revest.withdrawFNFT(id, tempSupply);
        destroyAccount(walletAddr, address(this));

        {
            assertEq(
                USDC.balanceOf(bob),
                revest.getValue(id) * tempSupply,
                "alice balance did not increase by expected amount"
            );

            assertEq(
                USDC.balanceOf(bob),
                tempSupply * (amount + additionalDepositAmount),
                "full amount not transfered to bob"
            );
        }

        changePrank(alice);
        revest.withdrawFNFT(id, tempSupply);

        assertEq(
            USDC.balanceOf(alice), preBal - USDC.balanceOf(bob), "alice balance did not increase by expected amount"
        );
    }

    function testMetadataFunctions() public {
        uint256 amount = 1.5e6;
        uint256 supply = 1;

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory supplies = new uint[](1);
        supplies[0] = supply;

        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(USDC),
            fnftId: 0,
            lockManager: address(lockManager_timelock),
            nonce: 0,
            maturityExtension: false
        });

        //TODO: Once we figure out the metadata handler
        //This is only meant to fill the coverage test

        (uint id, ) = revest.mintTimeLock(block.timestamp + 1 weeks + 6 hours, recipients, supplies, amount, config);
        skip(2 weeks);
        assert(fnftHandler.exists(id));

        //TODO
        string memory uri = fnftHandler.uri(id);
        (string memory baseRenderURI,) = fnftHandler.renderTokenURI(id);

        string memory metadata = metadataHandler.generateMetadata(address(revest), id);

        console.log("uri: %s", uri);
        console.log("------------------");
        console.log("baseRenderURI: %s", baseRenderURI);
        console.log("------------------");
        console.log("%s", metadata);

        changePrank(revest.owner());
        revest.changeMetadataHandler(address(0xdead));
        assertEq(address(revest.metadataHandler()), address(0xdead), "metadata handler not updated");
    }

    function testWithdrawFNFTSteam() public {
        uint256 supply = 10e6;
        uint256 depositAmount = 10e5;
        uint256 preBal = USDC.balanceOf(alice);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory supplies = new uint[](1);
        supplies[0] = supply;

        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(USDC),
            lockManager: address(lockManager_timelock),
            nonce: 0,
            fnftId: 0,
            maturityExtension: false
        });

        config.handler = address(fnftHandler);

        uint256 currentTime = block.timestamp;
        uint256 endTime = block.timestamp + 2 weeks;

        (uint256 fnftId, bytes32 lockId) = revest.mintTimeStream(endTime, recipients, depositAmount, config);

        // Let's fast forward time by 1 week
        skip(1 weeks);

        // Now Alice calls the withdrawFNFTSteam function

        uint256 bal = USDC.balanceOf(alice);

        revest.withdrawFNFTSteam(fnftId);
        uint256 withdrawnAmount = USDC.balanceOf(alice) - bal;


        // Check that Alice's balance has increased by the correct amount
        uint256 expectedIncrease = 1 weeks; // Replace with actual rate of increase
        assertEq(withdrawnAmount, 10e5 * expectedIncrease, "Alice's balance did not increase correctly");

        // Check that the total supply of FNFTs has decreased by the correct amount
        uint256 totalSupply = fnftHandler.totalSupply(fnftId);
        // assertEq(totalSupply, initialSupply - expectedIncrease, "Total supply did not decrease correctly");
    }
    function testWithdrawFNFTSteamQuadratic() public {
        uint256 supply = 10e6;
        uint256 depositAmount = 10e5;
        uint256 preBal = USDC.balanceOf(alice);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory supplies = new uint[](1);
        supplies[0] = supply;

        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(USDC),
            lockManager: address(lockManager_timelock),
            nonce: 0,
            fnftId: 0,
            maturityExtension: false
        });

        config.handler = address(fnftHandler);

        uint256 currentTime = block.timestamp;
        uint256 endTime = block.timestamp + 2 weeks;

        (uint256 fnftId, bytes32 lockId) = revest.mintTimeStream(endTime, recipients, depositAmount, config);

        // Let's fast forward time by 1 week
        skip(1 weeks);

        // Now Alice calls the withdrawFNFTSteam function
        uint256 bal = USDC.balanceOf(alice);

        revest.withdrawFNFTSteamQuadratic(fnftId);
        uint256 withdrawnAmount = USDC.balanceOf(alice) - bal;

        // Check that Alice's balance has increased by the correct amount
        uint256 expectedIncrease = 1 weeks; // Replace with actual rate of increase
        assertEq(withdrawnAmount, 10e5 * expectedIncrease / 2, "Alice's balance did not increase correctly");

        // Check that the total supply of FNFTs has decreased by the correct amount
        uint256 totalSupply = fnftHandler.totalSupply(fnftId);
        // assertEq(totalSupply, initialSupply - expectedIncrease, "Total supply did not decrease correctly");
    }

    function testWithdrawFNFTSteamQuadraticOffset() public {
        uint256 supply = 10e6;
        uint256 depositAmount = 10e5;
        uint256 preBal = USDC.balanceOf(alice);

        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        uint256[] memory supplies = new uint[](1);
        supplies[0] = supply;

        IController.FNFTConfig memory config = IController.FNFTConfig({
            handler: address(fnftHandler),
            asset: address(USDC),
            lockManager: address(lockManager_timelock),
            nonce: 0,
            fnftId: 0,
            maturityExtension: false
        });

        config.handler = address(fnftHandler);

        uint256 currentTime = block.timestamp;
        uint256 endTime = block.timestamp + 40 days;

        (uint256 fnftId, bytes32 lockId) = revest.mintTimeStream(endTime, recipients, depositAmount, config);

        // Let's fast forward time by 1 week
        skip(4 days);

        // Now Alice calls the withdrawFNFTSteam function

        uint256 bal = USDC.balanceOf(alice);

        revest.withdrawFNFTSteamQuadratic(fnftId);
        uint256 withdrawnAmount = USDC.balanceOf(alice) - bal;

        // Check that Alice's balance has increased by the correct amount
        uint256 expectedIncrease = 4 days; // Replace with actual rate of increase
        uint256 multiplier = 10;
        assertEq(withdrawnAmount, 10e5 * expectedIncrease / multiplier, "Alice's balance did not increase correctly");

        // Check that the total supply of FNFTs has decreased by the correct amount
        uint256 totalSupply = fnftHandler.totalSupply(fnftId);
        // assertEq(totalSupply, initialSupply - expectedIncrease, "Total supply did not decrease correctly");
    }
}
