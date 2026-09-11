// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/EscrowVault.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/mocks/MaliciousReentrantToken.sol";

contract EscrowVaultTest is Test {
    EscrowVault vault;
    MockUSDC usdc;

    uint256 buyerPk = 0xB0710;
    uint256 otherPk = 0xBAD;
    address buyer;
    address other;
    address provider = address(0xBEEF);
    address feeSink = address(0xFEE5);
    address relayerOwner = address(0x0517);

    bytes32 constant DEAL_INTENT_TYPEHASH = keccak256(
        "DealIntent(address buyer,address provider,uint256 amount,bytes32 nonce,uint64 expiry)"
    );

    function setUp() public {
        buyer = vm.addr(buyerPk);
        other = vm.addr(otherPk);

        usdc = new MockUSDC();
        vault = new EscrowVault(address(usdc), feeSink, relayerOwner);

        usdc.mint(buyer, 1_000_000_000_000); // 1,000,000 USDC
        vm.prank(buyer);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ---- signing helpers ----------------------------------------------

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("A2AEscrowMonopolyEngine")),
                keccak256(bytes("6")),
                block.chainid,
                address(vault)
            )
        );
    }

    function _structHash(EscrowVault.DealIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DEAL_INTENT_TYPEHASH,
                intent.buyer,
                intent.provider,
                intent.amount,
                intent.nonce,
                intent.expiry
            )
        );
    }

    function _digest(EscrowVault.DealIntent memory intent) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), _structHash(intent)));
    }

    function _sign(uint256 pk, EscrowVault.DealIntent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(intent));
        return abi.encodePacked(r, s, v);
    }

    function _intent(uint256 amount, uint64 expiry, bytes32 nonce) internal view returns (EscrowVault.DealIntent memory) {
        return EscrowVault.DealIntent({
            buyer: buyer,
            provider: provider,
            amount: amount,
            nonce: nonce,
            expiry: expiry
        });
    }

    // ==================== fundAndSettle: instant tier ====================

    function test_FundAndSettle_SplitsFeeCorrectly_LowTier() public {
        // 5 USDC, under 10 USDC threshold -> 250 bps
        uint256 amount = 5_000_000;
        EscrowVault.DealIntent memory intent = _intent(amount, uint64(block.timestamp + 1 hours), bytes32("n1"));
        bytes memory sig = _sign(buyerPk, intent);

        vault.fundAndSettle(intent, sig);

        (uint256 expectedFee, uint256 expectedNet) = vault.computeFee(amount);
        assertEq(expectedFee, 125_000); // 2.5% of 5,000,000
        assertEq(usdc.balanceOf(feeSink), expectedFee);
        assertEq(usdc.balanceOf(provider), expectedNet);
    }

    function test_FundAndSettle_SplitsFeeCorrectly_HighTier() public {
        // exactly at threshold -> HIGH tier per amount < TIER_THRESHOLD semantics
        uint256 amount = 10_000_000;
        EscrowVault.DealIntent memory intent = _intent(amount, uint64(block.timestamp + 1 hours), bytes32("n2"));
        bytes memory sig = _sign(buyerPk, intent);

        vault.fundAndSettle(intent, sig);

        (uint256 fee, uint256 net) = vault.computeFee(amount);
        assertEq(fee, 100_000); // 1.0% of 10,000,000
        assertEq(usdc.balanceOf(feeSink), fee);
        assertEq(usdc.balanceOf(provider), net);
    }

    function test_ComputeFee_TierBoundary_OneWeiBelowThreshold() public view {
        (uint256 fee, ) = vault.computeFee(vault.TIER_THRESHOLD() - 1);
        assertEq(fee, ((vault.TIER_THRESHOLD() - 1) * 250) / 10_000);
    }

    function test_ComputeFee_TierBoundary_ExactlyAtThreshold() public view {
        (uint256 fee, ) = vault.computeFee(vault.TIER_THRESHOLD());
        assertEq(fee, (vault.TIER_THRESHOLD() * 100) / 10_000);
    }

    function testFuzz_ComputeFee_FeePlusNetAlwaysEqualsAmount(uint256 amount) public view {
        amount = bound(amount, 1, 1_000_000_000_000_000);
        (uint256 fee, uint256 net) = vault.computeFee(amount);
        assertEq(fee + net, amount);
        assertLe(fee, amount);
    }

    function test_FundAndSettle_RevertsOnReplayedDealId() public {
        EscrowVault.DealIntent memory intent = _intent(5_000_000, uint64(block.timestamp + 1 hours), bytes32("replay"));
        bytes memory sig = _sign(buyerPk, intent);

        vault.fundAndSettle(intent, sig);

        vm.expectRevert(bytes("DEAL_EXISTS"));
        vault.fundAndSettle(intent, sig);
    }

    function test_FundAndSettle_RevertsOnExpiredIntent() public {
        EscrowVault.DealIntent memory intent = _intent(5_000_000, uint64(block.timestamp), bytes32("exp"));
        bytes memory sig = _sign(buyerPk, intent);

        vm.warp(block.timestamp + 1);
        vm.expectRevert(bytes("EXPIRED"));
        vault.fundAndSettle(intent, sig);
    }

    function test_FundAndSettle_RevertsOnWrongSigner() public {
        EscrowVault.DealIntent memory intent = _intent(5_000_000, uint64(block.timestamp + 1 hours), bytes32("badsig"));
        // Signed by `other`, but intent.buyer is `buyer` -> recovered != intent.buyer
        bytes memory sig = _sign(otherPk, intent);

        vm.expectRevert(bytes("INVALID_SIGNATURE"));
        vault.fundAndSettle(intent, sig);
    }

    function test_FundAndSettle_RevertsOnTamperedAmount() public {
        // Sign for 5 USDC, then submit with amount bumped to 50 USDC.
        // Must fail signature check because the signed digest binds amount.
        EscrowVault.DealIntent memory signedIntent = _intent(5_000_000, uint64(block.timestamp + 1 hours), bytes32("tamper"));
        bytes memory sig = _sign(buyerPk, signedIntent);

        EscrowVault.DealIntent memory tamperedIntent = signedIntent;
        tamperedIntent.amount = 50_000_000;

        vm.expectRevert(bytes("INVALID_SIGNATURE"));
        vault.fundAndSettle(tamperedIntent, sig);
    }

    function test_Constructor_RevertsOnZeroUsdcAddress() public {
        vm.expectRevert(bytes("INVALID_ADDRESS"));
        new EscrowVault(address(0), feeSink, relayerOwner);
    }

    function test_Constructor_RevertsOnZeroFeeSinkAddress() public {
        vm.expectRevert(bytes("INVALID_ADDRESS"));
        new EscrowVault(address(usdc), address(0), relayerOwner);
    }

    function test_FundAndSettle_RevertsOnZeroBuyer() public {
        // Can't get a valid signature recovering to address(0) (OZ ECDSA
        // reverts on that internally), so this exercises the explicit
        // ZERO_BUYER fast-fail path directly rather than routing through
        // a signature that could never validly recover to intent.buyer.
        EscrowVault.DealIntent memory intent = EscrowVault.DealIntent({
            buyer: address(0),
            provider: provider,
            amount: 5_000_000,
            nonce: bytes32("zb"),
            expiry: uint64(block.timestamp + 1 hours)
        });
        bytes memory sig = _sign(buyerPk, intent);

        vm.expectRevert(bytes("ZERO_BUYER"));
        vault.fundAndSettle(intent, sig);
    }

    function test_FundAndSettle_RevertsOnZeroAmount() public {
        EscrowVault.DealIntent memory intent = _intent(0, uint64(block.timestamp + 1 hours), bytes32("za"));
        bytes memory sig = _sign(buyerPk, intent);

        vm.expectRevert(bytes("ZERO_AMOUNT"));
        vault.fundAndSettle(intent, sig);
    }

    function test_FundAndSettle_RevertsOnZeroProvider() public {
        EscrowVault.DealIntent memory intent = EscrowVault.DealIntent({
            buyer: buyer,
            provider: address(0),
            amount: 5_000_000,
            nonce: bytes32("zp"),
            expiry: uint64(block.timestamp + 1 hours)
        });
        bytes memory sig = _sign(buyerPk, intent);

        vm.expectRevert(bytes("ZERO_PROVIDER"));
        vault.fundAndSettle(intent, sig);
    }

    function test_CrossChainReplay_SignatureInvalidAfterChainIdChange() public {
        EscrowVault.DealIntent memory intent = _intent(5_000_000, uint64(block.timestamp + 1 hours), bytes32("xchain"));
        bytes memory sig = _sign(buyerPk, intent); // signed against current chainid

        vm.chainId(999999); // simulate replay attempt on a different chain
        vm.expectRevert(bytes("INVALID_SIGNATURE"));
        vault.fundAndSettle(intent, sig);
    }

    // ==================== fund / release / refund: held tier ====================

    function test_Fund_LocksFullPrincipal_NoFeeTaken() public {
        uint256 amount = 50_000_000; // held tier
        EscrowVault.DealIntent memory intent = _intent(amount, uint64(block.timestamp + 1 days), bytes32("hold1"));
        bytes memory sig = _sign(buyerPk, intent);

        vault.fund(intent, sig);

        assertEq(usdc.balanceOf(address(vault)), amount);
        assertEq(usdc.balanceOf(feeSink), 0);
    }

    function test_Release_OnlyOwnerCanCall() public {
        bytes32 dealId = _fundHeldDeal(50_000_000, bytes32("hold2"));

        vm.prank(other); // not the relayer owner
        vm.expectRevert();
        vault.release(dealId);
    }

    function test_Release_TransfersFeeAndNetCorrectly() public {
        uint256 amount = 50_000_000;
        bytes32 dealId = _fundHeldDeal(amount, bytes32("hold3"));

        vm.prank(relayerOwner);
        vault.release(dealId);

        (uint256 fee, uint256 net) = vault.computeFee(amount);
        assertEq(usdc.balanceOf(feeSink), fee);
        assertEq(usdc.balanceOf(provider), net);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_Release_RevertsIfAlreadyReleased() public {
        bytes32 dealId = _fundHeldDeal(50_000_000, bytes32("hold4"));

        vm.prank(relayerOwner);
        vault.release(dealId);

        vm.prank(relayerOwner);
        vm.expectRevert(bytes("NOT_HELD"));
        vault.release(dealId);
    }

    function test_Refund_RevertsBeforeExpiry() public {
        bytes32 dealId = _fundHeldDeal(50_000_000, bytes32("hold5"));

        vm.expectRevert(bytes("NOT_EXPIRED"));
        vault.refund(dealId);
    }

    function test_Refund_ReturnsFullPrincipal_CallableByAnyone() public {
        uint256 amount = 50_000_000;
        uint64 expiry = uint64(block.timestamp + 1 days);
        EscrowVault.DealIntent memory intent = _intent(amount, expiry, bytes32("hold6"));
        bytes memory sig = _sign(buyerPk, intent);
        vault.fund(intent, sig);
        bytes32 dealId = vault.deriveDealId(intent);

        vm.warp(expiry + 1);

        uint256 buyerBalBefore = usdc.balanceOf(buyer);
        vm.prank(other); // permissionless: arbitrary caller, e.g. cron sweep
        vault.refund(dealId);

        assertEq(usdc.balanceOf(buyer), buyerBalBefore + amount);
    }

    function test_Refund_RevertsAfterAlreadyReleased() public {
        bytes32 dealId = _fundHeldDeal(50_000_000, bytes32("hold7"));
        vm.prank(relayerOwner);
        vault.release(dealId);

        vm.expectRevert(bytes("NOT_HELD"));
        vault.refund(dealId);
    }

    function test_ReleaseAndRefund_NeverBothSucceed() public {
        // Invariant: exactly one of release/refund can ever succeed per deal.
        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes32 dealId = _fundHeldDeal(50_000_000, bytes32("mutex"), expiry);

        vm.prank(relayerOwner);
        vault.release(dealId);

        vm.warp(expiry + 1);
        vm.expectRevert(bytes("NOT_HELD"));
        vault.refund(dealId);
    }

    // ==================== Reentrancy ====================

    function test_Reentrancy_FundAndSettleBlockedAgainstHostileToken() public {
        MaliciousReentrantToken evilToken = new MaliciousReentrantToken();
        EscrowVault evilVault = new EscrowVault(address(evilToken), feeSink, relayerOwner);

        evilToken.mint(buyer, 1_000_000_000);
        vm.prank(buyer);
        evilToken.approve(address(evilVault), type(uint256).max);

        EscrowVault.DealIntent memory intent1 = EscrowVault.DealIntent({
            buyer: buyer,
            provider: provider,
            amount: 5_000_000,
            nonce: bytes32("re1"),
            expiry: uint64(block.timestamp + 1 hours)
        });
        bytes memory sig1 = _signFor(evilVault, buyerPk, intent1);

        // NOTE: `DealIntent memory intent2 = intent1;` would alias the same
        // memory slot in Solidity (memory-to-memory struct assignment is a
        // reference, not a copy) — mutating intent2.nonce afterward would
        // silently corrupt intent1 too. Building it as a fresh literal
        // instead so the two intents are genuinely independent.
        EscrowVault.DealIntent memory intent2 = EscrowVault.DealIntent({
            buyer: buyer,
            provider: provider,
            amount: 5_000_000,
            nonce: bytes32("re2"),
            expiry: uint64(block.timestamp + 1 hours)
        });

        bytes memory sig2 = _signFor(evilVault, buyerPk, intent2);

        // Arm the token to attempt a reentrant fundAndSettle call using a
        // DIFFERENT dealId (re2) during the outer call's transferFrom.
        // If ReentrancyGuard is working, this inner call reverts and the
        // outer call still completes normally with only the outer deal settled.
        evilToken.arm(
            address(evilVault),
            abi.encodeWithSelector(EscrowVault.fundAndSettle.selector, intent2, sig2)
        );

        evilVault.fundAndSettle(intent1, sig1);

        // The reentrant deal must NOT have gone through.
        bytes32 dealId2 = evilVault.deriveDealId(intent2);
        (, , , , EscrowVault.Status status2) = evilVault.deals(dealId2);
        assertEq(uint256(status2), uint256(EscrowVault.Status.NONE));

        // The outer deal DID go through exactly once.
        bytes32 dealId1 = evilVault.deriveDealId(intent1);
        (, , , , EscrowVault.Status status1) = evilVault.deals(dealId1);
        assertEq(uint256(status1), uint256(EscrowVault.Status.SETTLED));
    }

    // ==================== Pausable circuit breaker ====================

    function test_Pause_BlocksNewFundAndSettle() public {
        vm.prank(relayerOwner);
        vault.pause();

        EscrowVault.DealIntent memory intent = _intent(5_000_000, uint64(block.timestamp + 1 hours), bytes32("paused1"));
        bytes memory sig = _sign(buyerPk, intent);

        vm.expectRevert();
        vault.fundAndSettle(intent, sig);
    }

    function test_Pause_BlocksNewFund() public {
        vm.prank(relayerOwner);
        vault.pause();

        EscrowVault.DealIntent memory intent = _intent(50_000_000, uint64(block.timestamp + 1 hours), bytes32("paused2"));
        bytes memory sig = _sign(buyerPk, intent);

        vm.expectRevert();
        vault.fund(intent, sig);
    }

    function test_Pause_DoesNotBlockExistingRelease() public {
        bytes32 dealId = _fundHeldDeal(50_000_000, bytes32("paused3"));

        vm.prank(relayerOwner);
        vault.pause();

        // release must still work while paused -- funds already in vault
        // are never frozen by the circuit breaker.
        vm.prank(relayerOwner);
        vault.release(dealId);

        (, , , , EscrowVault.Status status) = vault.deals(dealId);
        assertEq(uint256(status), uint256(EscrowVault.Status.SETTLED));
    }

    function test_Pause_DoesNotBlockExistingRefund() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes32 dealId = _fundHeldDeal(50_000_000, bytes32("paused4"), expiry);

        vm.prank(relayerOwner);
        vault.pause();

        vm.warp(expiry + 1);
        vault.refund(dealId); // must still succeed while paused

        (, , , , EscrowVault.Status status) = vault.deals(dealId);
        assertEq(uint256(status), uint256(EscrowVault.Status.REFUNDED));
    }

    function test_Pause_OnlyOwnerCanPauseOrUnpause() public {
        vm.prank(other);
        vm.expectRevert();
        vault.pause();
    }

    function test_Unpause_RestoresNewDealCreation() public {
        vm.startPrank(relayerOwner);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        EscrowVault.DealIntent memory intent = _intent(5_000_000, uint64(block.timestamp + 1 hours), bytes32("unpaused"));
        bytes memory sig = _sign(buyerPk, intent);

        vault.fundAndSettle(intent, sig); // should not revert
        bytes32 dealId = vault.deriveDealId(intent);
        (, , , , EscrowVault.Status status) = vault.deals(dealId);
        assertEq(uint256(status), uint256(EscrowVault.Status.SETTLED));
    }

    // ==================== Ownership hardening ====================

    function test_RenounceOwnership_AlwaysReverts() public {
        vm.prank(relayerOwner);
        vm.expectRevert(bytes("RENOUNCE_DISABLED"));
        vault.renounceOwnership();
    }

    function test_TransferOwnership_StillWorks_ForRelayerKeyRotation() public {
        address newRelayer = address(0xCAFE);

        vm.prank(relayerOwner);
        vault.transferOwnership(newRelayer);

        assertEq(vault.owner(), newRelayer);

        bytes32 dealId = _fundHeldDeal(50_000_000, bytes32("rotate"));

        // old owner can no longer release
        vm.prank(relayerOwner);
        vm.expectRevert();
        vault.release(dealId);

        // new owner can
        vm.prank(newRelayer);
        vault.release(dealId);
    }

    // ==================== helpers ====================

    function _fundHeldDeal(uint256 amount, bytes32 nonce) internal returns (bytes32 dealId) {
        return _fundHeldDeal(amount, nonce, uint64(block.timestamp + 1 days));
    }

    function _fundHeldDeal(uint256 amount, bytes32 nonce, uint64 expiry) internal returns (bytes32 dealId) {
        EscrowVault.DealIntent memory intent = _intent(amount, expiry, nonce);
        bytes memory sig = _sign(buyerPk, intent);
        vault.fund(intent, sig);
        return vault.deriveDealId(intent);
    }

    // Same signing logic but parameterized on an arbitrary vault instance,
    // needed for the reentrancy test which deploys a second vault wired to
    // the malicious token.
    function _signFor(EscrowVault v, uint256 pk, EscrowVault.DealIntent memory intent) internal view returns (bytes memory) {
        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("A2AEscrowMonopolyEngine")),
                keccak256(bytes("6")),
                block.chainid,
                address(v)
            )
        );
        bytes32 structHash = _structHash(intent);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 vSig, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, vSig);
    }
}
