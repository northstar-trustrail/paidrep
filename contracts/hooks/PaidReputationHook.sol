// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC8183Hook} from "../IERC8183Hook.sol";
import {ERC8183} from "../ERC8183.sol";

/// @notice Minimal ERC-8004 IdentityRegistry surface used by the hook.
interface IIdentityRegistry8004 {
    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool);
}

/// @notice Minimal ERC-8004 ReputationRegistry surface used by the hook.
interface IReputationRegistry8004 {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
}

/// @title PaidReputationHook
/// @notice ERC-8183 hook that turns *paid, evaluated* agent jobs into ERC-8004 reputation.
///
///         Problem: ERC-8004 feedback is permissionless, so anyone can spam an agent with
///         fake 5-star reviews. Solution: this hook is the only writer for its own client
///         address in the ReputationRegistry, and it only writes when an ERC-8183 escrow
///         actually settled (or an evaluator rejected) a funded job. Reading
///         `getSummary(agentId, [hook], "erc8183", ...)` therefore yields reputation that is
///         backed by real USDC that moved through escrow on Arc.
///
///         - beforeAction(fund): if the job names a provider agentId, the provider wallet must
///           be the owner/operator of that ERC-8004 identity (stops borrowing someone else's
///           reputation).
///         - afterAction(complete): feedback value=100 tag1="erc8183" tag2="completed", plus a
///           volume record value=<amount settled> (token decimals) tag2="paid".
///         - afterAction(reject) of a *submitted* job by the evaluator: value=0 tag2="rejected".
///
///         Registry-side failures never block escrow settlement (try/catch, fixed gas stipend),
///         so funds can't be stuck by a registry problem. Insufficient *transaction* gas reverts
///         instead, so gas estimation can't silently drop the reputation write (v1 bug).
contract PaidReputationHook is IERC8183Hook {
    using Strings for uint256;
    using Strings for address;

    ERC8183 public immutable escrow;
    IIdentityRegistry8004 public immutable identity;
    IReputationRegistry8004 public immutable reputation;
    uint8 public immutable tokenDecimals;

    /// @dev jobId => job was in Submitted state when reject was called
    mapping(uint256 => bool) private _rejectingSubmitted;

    event ReputationWritten(uint256 indexed jobId, uint256 indexed agentId, string tag2, int128 value);
    event ReputationWriteFailed(uint256 indexed jobId, uint256 indexed agentId, bytes reason);

    /// @dev Gas forwarded to each ReputationRegistry write (first write for a new client ~188k, later ~80k).
    uint256 public constant FEEDBACK_GAS = 250_000;

    error OnlyEscrow();
    /// @dev Reverting (instead of silently skipping) when gas is short makes eth_estimateGas
    ///      size the transaction correctly; otherwise try/catch hides an out-of-gas write.
    error InsufficientGasForFeedback();
    error ProviderDoesNotControlAgent(address provider, uint256 agentId);

    constructor(ERC8183 escrow_, IIdentityRegistry8004 identity_, IReputationRegistry8004 reputation_, uint8 tokenDecimals_) {
        escrow = escrow_;
        identity = identity_;
        reputation = reputation_;
        tokenDecimals = tokenDecimals_;
    }

    modifier onlyEscrow() {
        if (msg.sender != address(escrow)) revert OnlyEscrow();
        _;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC8183Hook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata) external onlyEscrow {
        if (selector == ERC8183.fund.selector) {
            ERC8183.Job memory job = escrow.getJob(jobId);
            if (job.providerAgentId != 0 && !identity.isAuthorizedOrOwner(job.provider, job.providerAgentId)) {
                revert ProviderDoesNotControlAgent(job.provider, job.providerAgentId);
            }
        } else if (selector == ERC8183.reject.selector) {
            ERC8183.Job memory job = escrow.getJob(jobId);
            _rejectingSubmitted[jobId] = (job.status == ERC8183.JobStatus.Submitted);
        }
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external onlyEscrow {
        if (selector == ERC8183.complete.selector) {
            ERC8183.Job memory job = escrow.getJob(jobId);
            if (job.providerAgentId == 0) return;
            (, bytes32 reason,) = abi.decode(data, (address, bytes32, bytes));
            _write(jobId, job.providerAgentId, 100, 0, "completed", reason);
            uint256 paid = job.budget; // gross amount escrowed for this job
            if (paid > 0 && paid <= uint256(uint128(type(int128).max))) {
                _write(jobId, job.providerAgentId, int128(int256(paid)), tokenDecimals, "paid", reason);
            }
        } else if (selector == ERC8183.reject.selector) {
            bool wasSubmitted = _rejectingSubmitted[jobId];
            delete _rejectingSubmitted[jobId];
            if (!wasSubmitted) return;
            ERC8183.Job memory job = escrow.getJob(jobId);
            if (job.providerAgentId == 0) return;
            (, bytes32 reason,) = abi.decode(data, (address, bytes32, bytes));
            _write(jobId, job.providerAgentId, 0, 0, "rejected", reason);
        }
    }

    function feedbackURI(uint256 jobId) public view returns (string memory) {
        return string.concat("erc8183:eip155:", block.chainid.toString(), ":", address(escrow).toHexString(), ":", jobId.toString());
    }

    function _write(uint256 jobId, uint256 agentId, int128 value, uint8 decimals, string memory tag2, bytes32 reason)
        internal
    {
        if (gasleft() < (FEEDBACK_GAS * 64) / 63 + 20_000) revert InsufficientGasForFeedback();
        try reputation.giveFeedback{gas: FEEDBACK_GAS}(agentId, value, decimals, "erc8183", tag2, "", feedbackURI(jobId), reason) {
            emit ReputationWritten(jobId, agentId, tag2, value);
        } catch (bytes memory err) {
            emit ReputationWriteFailed(jobId, agentId, err);
        }
    }
}
