// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title FlashLoan Drain Trap - Response Contract
/// @notice Simple registry that detects sudden reserve spikes (flash-loan style)
///         and temporarily pauses a pair (by recording pause state).
/// @dev This contract does NOT move funds. Integrations (router/UI) should call
///      `isPaused(pair)` before allowing sensitive actions.
contract FlashLoanDrainResponse {
    address public governance;

    // Parameters that can be tuned by governance
    struct Params {
        uint256 multiplierNumerator;   // e.g., 3 for "3x"
        uint256 multiplierDenominator; // e.g., 1
        uint256 pauseDurationSeconds;  // how long to pause (in seconds)
        uint256 maxDailyTriggers;      // safety: max automatic triggers per pair per day
    }
    Params public params;

    struct PairState {
        uint256 pauseExpiry;      // timestamp until which pair is paused (0 = not paused)
        uint256 lastTriggerDay;   // day index for rate-limiting
        uint256 triggersToday;    // count of triggers today
    }
    mapping(address => PairState) public pairState;

    // Events
    event TrapFired(address indexed pair, uint256 reserveNow, uint256 reservePrev, uint256 pauseUntil, string metadata);
    event IncidentRecorded(bytes32 indexed incidentHash, address indexed reporter, string metadata);
    event ParamsUpdated(address indexed setter, Params newParams);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);
    event ManualUnpause(address indexed pair, address indexed caller);

    modifier onlyGov() {
        require(msg.sender == governance, "FLD: only governance");
        _;
    }

    constructor(address _governance) {
        require(_governance != address(0), "FLD: zero gov");
        governance = _governance;

        // sensible defaults: trigger when reserveNow >= reservePrev * 3, pause for 1 hour, up to 3 triggers/day
        params = Params({
            multiplierNumerator: 3,
            multiplierDenominator: 1,
            pauseDurationSeconds: 3600,
            maxDailyTriggers: 3
        });
    }

    /// @notice Called by an off-chain monitor/keeper after observing reserves.
    /// @param pair Pair address (used as registry key)
    /// @param reserveNow Current reserve observed (raw uint from pair)
    /// @param reservePrev Previous reserve observed (raw uint from prior block)
    /// @param metadata Optional short evidence string (CID, tx hash list, notes)
    function evaluateAndTrigger(
        address pair,
        uint256 reserveNow,
        uint256 reservePrev,
        string calldata metadata
    ) external {
        require(pair != address(0), "FLD: zero pair");

        // If no previous reserve, just record evidence and return
        if (reservePrev == 0) {
            bytes32 h = _emitIncident(pair, reserveNow, reservePrev, metadata);
            emit IncidentRecorded(h, msg.sender, metadata);
            return;
        }

        // Rate-limit per pair per day
        uint256 day = block.timestamp / 1 days;
        PairState storage st = pairState[pair];
        if (st.lastTriggerDay != day) {
            st.lastTriggerDay = day;
            st.triggersToday = 0;
        }

        // If already paused, still record evidence but don't re-pause beyond safety limits
        if (block.timestamp <= st.pauseExpiry) {
            bytes32 h = _emitIncident(pair, reserveNow, reservePrev, metadata);
            emit IncidentRecorded(h, msg.sender, metadata);
            return;
        }

        // Check multiplier condition without overflow:
        // trigger if reserveNow * denominator >= reservePrev * numerator
        // (all are uint256 and small multiplier avoids overflow in practice)
        uint256 left = reserveNow * params.multiplierDenominator;
        uint256 right = reservePrev * params.multiplierNumerator;

        if (left >= right) {
            // Respect daily trigger limit
            if (st.triggersToday >= params.maxDailyTriggers) {
                // record incident but do not auto-pause
                bytes32 h = _emitIncident(pair, reserveNow, reservePrev, metadata);
                emit IncidentRecorded(h, msg.sender, metadata);
                return;
            }

            // Apply pause
            uint256 pauseUntil = block.timestamp + params.pauseDurationSeconds;
            st.pauseExpiry = pauseUntil;
            st.triggersToday += 1;

            bytes32 h = _emitIncident(pair, reserveNow, reservePrev, metadata);
            emit TrapFired(pair, reserveNow, reservePrev, pauseUntil, metadata);
            emit IncidentRecorded(h, msg.sender, metadata);
        } else {
            // No trigger — but emit evidence for observability
            bytes32 h = _emitIncident(pair, reserveNow, reservePrev, metadata);
            emit IncidentRecorded(h, msg.sender, metadata);
        }
    }

    /// @notice Governance manually unpauses a pair (e.g., after investigation)
    function governanceUnpause(address pair) external onlyGov {
        PairState storage st = pairState[pair];
        st.pauseExpiry = 0;
        st.triggersToday = 0;
        emit ManualUnpause(pair, msg.sender);
    }

    /// @notice Check whether a pair is currently paused
    function isPaused(address pair) external view returns (bool) {
        return block.timestamp <= pairState[pair].pauseExpiry;
    }

    /// @notice Get pause expiry timestamp for a pair (0 if not paused)
    function getPauseExpiry(address pair) external view returns (uint256) {
        return pairState[pair].pauseExpiry;
    }

    /// @notice Governance can update detector parameters
    function setParams(
        uint256 multiplierNumerator,
        uint256 multiplierDenominator,
        uint256 pauseDurationSeconds,
        uint256 maxDailyTriggers
    ) external onlyGov {
        require(multiplierDenominator != 0, "FLD: zero denom");
        require(multiplierNumerator >= multiplierDenominator, "FLD: numerator < denom");
        params = Params({
            multiplierNumerator: multiplierNumerator,
            multiplierDenominator: multiplierDenominator,
            pauseDurationSeconds: pauseDurationSeconds,
            maxDailyTriggers: maxDailyTriggers
        });
        emit ParamsUpdated(msg.sender, params);
    }

    /// @notice Transfer governance to new address
    function transferGovernance(address newGov) external onlyGov {
        require(newGov != address(0), "FLD: zero new gov");
        address old = governance;
        governance = newGov;
        emit GovernanceTransferred(old, newGov);
    }

    /// @dev Emit an incident hash for off-chain auditability
    function _emitIncident(
        address pair,
        uint256 reserveNow,
        uint256 reservePrev,
        string calldata metadata
    ) internal returns (bytes32) {
        bytes32 h = keccak256(abi.encodePacked(block.number, block.timestamp, pair, msg.sender, reserveNow, reservePrev));
        // IncidentRecorded gets emitted by callers; return hash so caller can emit or log
        return h;
    }
}
