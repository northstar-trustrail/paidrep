// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC8183} from "../contracts/ERC8183.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {
    PaidReputationHook,
    IIdentityRegistry8004,
    IReputationRegistry8004
} from "../contracts/hooks/PaidReputationHook.sol";

interface IIdentityFull {
    function register(string memory agentURI) external returns (uint256 agentId);
}

interface IRepRead {
    function getSummary(uint256 agentId, address[] calldata clients, string calldata tag1, string calldata tag2)
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);
}

/// Runs against a fork of Arc mainnet so the real ERC-8004 registries are exercised.
/// forge test --fork-url https://rpc.mainnet.arc.io
contract PaidReputationHookForkTest is Test {
    address constant IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;

    ERC8183 escrow;
    PaidReputationHook hook;
    MockUSDC usdc;
    address admin = makeAddr("admin");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address evaluator = makeAddr("evaluator");
    address stranger = makeAddr("stranger");
    uint256 agentId;

    function setUp() public {
        if (IDENTITY.code.length == 0) vm.skip(true); // needs Arc fork
        usdc = new MockUSDC();
        ERC8183 impl = new ERC8183();
        escrow = ERC8183(address(new ERC1967Proxy(address(impl), abi.encodeCall(ERC8183.initialize, (admin, admin)))));
        hook = new PaidReputationHook(
            escrow, IIdentityRegistry8004(IDENTITY), IReputationRegistry8004(REPUTATION), 6
        );
        vm.startPrank(admin);
        escrow.setHookWhitelist(address(hook), true);
        escrow.setPaymentTokenAllowed(address(usdc), true);
        vm.stopPrank();
        vm.prank(provider);
        agentId = IIdentityFull(IDENTITY).register("data:application/json,{\"name\":\"test-agent\"}");
        usdc.mint(client, 100e6);
    }

    function _job(uint256 aid, address prov) internal returns (uint256 id) {
        vm.prank(client);
        id = escrow.createJob(prov, evaluator, uint48(block.timestamp + 1 days), "write a report", address(hook), aid);
        vm.prank(prov);
        escrow.setBudget(id, address(usdc), 5e6, "");
    }

    function _fund(uint256 id) internal {
        vm.startPrank(client);
        usdc.approve(address(escrow), 5e6);
        escrow.fund(id, address(usdc), 5e6, "");
        vm.stopPrank();
    }

    function _summary(string memory tag2) internal view returns (uint64 c, int128 v, uint8 d) {
        address[] memory clients = new address[](1);
        clients[0] = address(hook);
        return IRepRead(REPUTATION).getSummary(agentId, clients, "erc8183", tag2);
    }

    function test_completeWritesEscrowBackedReputation() public {
        uint256 id = _job(agentId, provider);
        _fund(id);
        vm.prank(provider);
        escrow.submit(id, keccak256("deliverable"), "");
        vm.prank(evaluator);
        escrow.complete(id, keccak256("looks good"), "");

        assertEq(usdc.balanceOf(provider), 5e6);
        (uint64 c, int128 v,) = _summary("completed");
        assertEq(c, 1);
        assertEq(v, 100);
        (uint64 c2, int128 v2, uint8 d2) = _summary("paid");
        assertEq(c2, 1);
        assertEq(v2, 5e6);
        assertEq(d2, 6);
    }

    function test_rejectAfterSubmitWritesZero() public {
        uint256 id = _job(agentId, provider);
        _fund(id);
        vm.prank(provider);
        escrow.submit(id, keccak256("bad deliverable"), "");
        vm.prank(evaluator);
        escrow.reject(id, keccak256("incomplete"), "");
        assertEq(usdc.balanceOf(client), 100e6); // refunded
        (uint64 c, int128 v,) = _summary("rejected");
        assertEq(c, 1);
        assertEq(v, 0);
    }

    function test_rejectBeforeSubmitWritesNothing() public {
        uint256 id = _job(agentId, provider);
        _fund(id);
        vm.prank(evaluator);
        escrow.reject(id, keccak256("cancelled"), "");
        (uint64 c,,) = _summary("rejected");
        assertEq(c, 0);
    }

    function test_cannotBorrowSomeoneElsesAgentId() public {
        uint256 id = _job(agentId, stranger); // stranger claims provider's agentId
        vm.startPrank(client);
        usdc.approve(address(escrow), 5e6);
        vm.expectRevert(abi.encodeWithSelector(PaidReputationHook.ProviderDoesNotControlAgent.selector, stranger, agentId));
        escrow.fund(id, address(usdc), 5e6, "");
        vm.stopPrank();
    }

    function test_lowGasCompleteRevertsInsteadOfSkippingFeedback() public {
        uint256 id = _job(agentId, provider);
        _fund(id);
        vm.prank(provider);
        escrow.submit(id, keccak256("d"), "");
        vm.prank(evaluator);
        vm.expectRevert();
        escrow.complete{gas: 300_000}(id, keccak256("ok"), "");
        vm.prank(evaluator);
        escrow.complete(id, keccak256("ok"), "");
        (uint64 c2,,) = _summary("paid");
        assertEq(c2, 1);
    }

    function test_onlyEscrowCanCallHook() public {
        vm.expectRevert(PaidReputationHook.OnlyEscrow.selector);
        hook.afterAction(1, ERC8183.complete.selector, "");
    }

    function test_noAgentIdMeansPlainEscrow() public {
        uint256 id = _job(0, provider);
        _fund(id);
        vm.prank(provider);
        escrow.submit(id, keccak256("d"), "");
        vm.prank(evaluator);
        escrow.complete(id, keccak256("ok"), "");
        assertEq(usdc.balanceOf(provider), 5e6);
    }
}
