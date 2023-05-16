// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.7;

import "../../interfaces/ISwitchboard.sol";
import "../../interfaces/ICapacitor.sol";
import "../../interfaces/ISignatureVerifier.sol";

import "../../utils/AccessControl.sol";
import "../../libraries/SignatureVerifierLib.sol";
import "../../libraries/RescueFundsLib.sol";
import "../../libraries/FeesHelper.sol";
import "../../utils/AccessControlExtended.sol";

import {GOVERNANCE_ROLE, RESCUE_ROLE, WITHDRAW_ROLE, TRIP_ROLE, UNTRIP_ROLE, FEES_UPDATER_ROLE} from "../../utils/AccessRoles.sol";
import {TRIP_NATIVE_SIG_IDENTIFIER, L1_RECEIVE_GAS_LIMIT_UPDATE_SIG_IDENTIFIER, UNTRIP_NATIVE_SIG_IDENTIFIER, EXECUTION_OVERHEAD_UPDATE_SIG_IDENTIFIER, INITIAL_CONFIRMATION_GAS_LIMIT_UPDATE_SIG_IDENTIFIER, FEES_UPDATE_SIG_IDENTIFIER} from "../../utils/SigIdentifiers.sol";

/**

@title Native Switchboard Base Contract
@notice This contract serves as the base for the implementation of a switchboard for native cross-chain communication.
It provides the necessary functionalities to allow packets to be sent and received between chains and ensures proper handling
of fees, gas limits, and packet validation.
@dev This contract has access-controlled functions and connects to a capacitor contract that holds packets for the native bridge.
*/
abstract contract NativeSwitchboardBase is ISwitchboard, AccessControlExtended {
    struct Fees {
        uint256 switchboardFees;
        uint256 verificationFees;
    }

    ISignatureVerifier public signatureVerifier__;

    /**
     * @dev Flag that indicates if the global fuse is tripped, meaning no more packets can be sent.
     */
    bool public tripGlobalFuse;

    /**
     * @dev The capacitor contract that holds packets for the native bridge.
     */
    ICapacitor public capacitor__;

    /**
     * @dev Flag that indicates if the capacitor has been registered.
     */
    bool public isInitialised;

    /**
     * @dev The maximum packet size.
     */
    uint256 public maxPacketSize;

    /**
     * @dev The gas limit to be used for packet initiation.
     */
    uint256 public initiateGasLimit;

    /**
     * @dev Address of the remote native switchboard.
     */
    address public remoteNativeSwitchboard;
    address public socket;

    uint32 public immutable chainSlug;

    /**
     * @dev Stores the roots received from native bridge.
     */
    mapping(bytes32 => bytes32) public packetIdToRoot;

    /**
     * @dev Transmitter to next nonce.
     */
    mapping(address => uint256) public nextNonce;

    // destinationChainSlug => fees-struct with verificationFees and switchboardFees
    mapping(uint32 => Fees) public fees;

    /**
     * @dev Event emitted when the switchboard is tripped.
     */
    event SwitchboardTripped(bool tripGlobalFuse);

    /**
     * @dev Event emitted when the initiate gas limit is set.
     * @param gasLimit The new initiate gas limit value.
     */
    event InitiateGasLimitSet(uint256 gasLimit);

    /**
     * @dev Event emitted when the capacitor address is set.
     * @param capacitor The new capacitor address.
     */
    event CapacitorSet(address capacitor);

    /**
     * @dev Event emitted when a native confirmation is initiated.
     * @param packetId The packet ID.
     */
    event InitiatedNativeConfirmation(bytes32 packetId);

    /**
     * @dev This event is emitted when a new capacitor is registered.
     *     It includes the address of the capacitor and the maximum size of the packet allowed.
     * @param capacitor address of capacitor registered to switchboard
     * @param maxPacketSize maximum packets that can be set to capacitor
     */
    event CapacitorRegistered(address capacitor, uint256 maxPacketSize);

    /**
     * @dev This event is emitted when a new capacitor is registered.
     *     It includes the address of the capacitor and the maximum size of the packet allowed.
     * @param remoteNativeSwitchboard address of capacitor registered to switchboard
     */
    event UpdatedRemoteNativeSwitchboard(address remoteNativeSwitchboard);

    /**
     * @dev Event emitted when a root hash is received by the contract.
     * @param packetId The unique identifier of the packet.
     * @param root The root hash of the Merkle tree containing the transaction data.
     */
    event RootReceived(bytes32 packetId, bytes32 root);

    /**
     * @dev Emitted when a fees is set for switchboard
     * @param siblingChainSlug Chain slug of the sibling chain
     * @param fees fees struct with verificationFees and switchboardFees
     */
    event SwitchboardFeesSet(uint32 siblingChainSlug, Fees fees);

    /**
     * @dev Error thrown when the fees provided are not enough to execute the transaction.
     */
    error FeesNotEnough();

    /**
     * @dev Error thrown when the contract has already been initialized.
     */
    error AlreadyInitialised();

    /**
     * @dev Error thrown when the transaction is not sent by a valid sender.
     */
    error InvalidSender();

    /**
     * @dev Error thrown when a root hash cannot be found for the given packet ID.
     */
    error NoRootFound();

    /**
     * @dev Error thrown when the nonce of the transaction is invalid.
     */
    error InvalidNonce();

    /**
     * @dev Error thrown when a function can only be called by the Socket.
     */
    error OnlySocket();

    /**
     * @dev Modifier to ensure that a function can only be called by the remote switchboard.
     */
    modifier onlyRemoteSwitchboard() virtual {
        _;
    }

    /**
     * @dev Constructor function for the CrossChainReceiver contract.
     * @param socket_ The address of the remote switchboard.
     * @param chainSlug_ The identifier of the chain the contract is deployed on.
     * @param initiateGasLimit_ The gas limit for executing transactions.
     */
    constructor(
        address socket_,
        uint32 chainSlug_,
        uint256 initiateGasLimit_,
        ISignatureVerifier signatureVerifier_
    ) {
        socket = socket_;
        chainSlug = chainSlug_;
        initiateGasLimit = initiateGasLimit_;
        signatureVerifier__ = signatureVerifier_;
    }

    /**
     * @notice retrieves the Merkle root for a given packet ID
     * @param packetId_ packet ID
     * @return root Merkle root associated with the given packet ID
     * @dev Reverts with 'NoRootFound' error if no root is found for the given packet ID
     */
    function _getRoot(bytes32 packetId_) internal view returns (bytes32 root) {
        uint64 capacitorPacketCount = uint64(uint256(packetId_));
        root = capacitor__.getRootByCount(capacitorPacketCount);
        if (root == bytes32(0)) revert NoRootFound();
    }

    /**
     * @notice records the Merkle root for a given packet ID emitted by a remote switchboard
     * @param packetId_ packet ID
     * @param root_ Merkle root for the given packet ID
     */
    function receivePacket(
        bytes32 packetId_,
        bytes32 root_
    ) external onlyRemoteSwitchboard {
        packetIdToRoot[packetId_] = root_;
        emit RootReceived(packetId_, root_);
    }

    /**
     * @notice checks if a packet can be executed
     * @param root_ Merkle root associated with the packet ID
     * @param packetId_ packet ID
     * @return true if the packet satisfies all the checks and can be executed, false otherwise
     */
    function allowPacket(
        bytes32 root_,
        bytes32 packetId_,
        uint32,
        uint256
    ) external view override returns (bool) {
        if (tripGlobalFuse) return false;
        if (packetIdToRoot[packetId_] != root_) return false;

        return true;
    }

    /**
     * @notice receives fees to be paid to the relayer for executing the packet
     * @param dstChainSlug_ chain slug of the destination chain
     * @dev assumes that the amount is paid in the native currency of the destination chain and has 18 decimals
     */
    function payFees(uint32 dstChainSlug_) external payable override {}

    /**
     * @dev Get the minimum fees for a cross-chain transaction.
     * @param dstChainSlug_ The destination chain's slug.
     * @return switchboardFee_ The fee charged by the switchboard for the transaction.
     * @return verificationFee_ The fee charged by the verifier for the transaction.
     */
    function getMinFees(
        uint32 dstChainSlug_
    )
        external
        view
        override
        returns (uint256 switchboardFee_, uint256 verificationFee_)
    {
        return (
            fees[dstChainSlug_].switchboardFees,
            fees[dstChainSlug_].verificationFees
        );
    }

    function setFees(
        uint256 nonce_,
        uint32 dstChainSlug_,
        uint256 switchboardFees_,
        uint256 verificationFees_,
        bytes calldata signature_
    ) external override {
        address feesUpdater = signatureVerifier__.recoverSignerFromDigest(
            keccak256(
                abi.encode(
                    FEES_UPDATE_SIG_IDENTIFIER,
                    address(this),
                    chainSlug,
                    dstChainSlug_,
                    nonce_,
                    switchboardFees_,
                    verificationFees_
                )
            ),
            signature_
        );

        _checkRoleWithSlug(FEES_UPDATER_ROLE, dstChainSlug_, feesUpdater);

        uint256 nonce = nextNonce[feesUpdater]++;
        if (nonce_ != nonce) revert InvalidNonce();

        Fees memory feesObject = Fees({
            switchboardFees: switchboardFees_,
            verificationFees: verificationFees_
        });

        fees[dstChainSlug_] = feesObject;

        emit SwitchboardFeesSet(dstChainSlug_, feesObject);
    }

    /**
     * @notice set capacitor address and packet size
     * @param capacitor_ capacitor address
     * @param maxPacketSize_ max messages allowed in one packet
     */
    function registerCapacitor(
        uint32,
        address capacitor_,
        uint256 maxPacketSize_
    ) external override {
        if (msg.sender != socket) revert OnlySocket();
        if (isInitialised) revert AlreadyInitialised();

        isInitialised = true;
        maxPacketSize = maxPacketSize_;
        capacitor__ = ICapacitor(capacitor_);

        emit CapacitorRegistered(capacitor_, maxPacketSize_);
    }

    /**
     * @notice Allows to trip the global fuse and prevent the switchboard to process packets
     * @dev The function recovers the signer from the given signature and verifies if the signer has the TRIP_ROLE.
     *      The nonce must be equal to the next nonce of the caller. If the caller doesn't have the TRIP_ROLE or the nonce
     *      is incorrect, it will revert.
     *       Once the function is successful, the tripGlobalFuse variable is set to true and the SwitchboardTripped event is emitted.
     * @param nonce_ The nonce of the caller.
     * @param signature_ The signature of the message "TRIP" + chainSlug + nonce_ + true.
     */
    function tripGlobal(uint256 nonce_, bytes memory signature_) external {
        address watcher = SignatureVerifierLib.recoverSignerFromDigest(
            // it includes trip status at the end
            keccak256(
                abi.encode(TRIP_NATIVE_SIG_IDENTIFIER, chainSlug, nonce_, true)
            ),
            signature_
        );

        _checkRole(TRIP_ROLE, watcher);
        uint256 nonce = nextNonce[watcher]++;
        if (nonce_ != nonce) revert InvalidNonce();

        tripGlobalFuse = true;
        emit SwitchboardTripped(true);
    }

    /**
     * @notice Allows a watcher to untrip the switchboard by providing a signature and a nonce.
     * @dev To untrip, the watcher must have the UNTRIP_ROLE. The signature must be created by signing the concatenation of the following values: "UNTRIP", the chainSlug, the nonce and false.
     * @param nonce_ The nonce to prevent replay attacks.
     * @param signature_ The signature created by the watcher.
     */
    function untrip(uint256 nonce_, bytes memory signature_) external {
        address watcher = SignatureVerifierLib.recoverSignerFromDigest(
            // it includes trip status at the end
            keccak256(
                abi.encode(
                    UNTRIP_NATIVE_SIG_IDENTIFIER,
                    chainSlug,
                    nonce_,
                    false
                )
            ),
            signature_
        );

        _checkRole(UNTRIP_ROLE, watcher);
        uint256 nonce = nextNonce[watcher]++;
        if (nonce_ != nonce) revert InvalidNonce();

        tripGlobalFuse = false;
        emit SwitchboardTripped(false);
    }

    /**
    @dev Update the address of the remote native switchboard contract.
    @param remoteNativeSwitchboard_ The address of the new remote native switchboard contract.
    @notice This function can only be called by an account with the GOVERNANCE_ROLE.
    @notice Emits an UpdatedRemoteNativeSwitchboard event.
    */
    function updateRemoteNativeSwitchboard(
        address remoteNativeSwitchboard_
    ) external onlyRole(GOVERNANCE_ROLE) {
        remoteNativeSwitchboard = remoteNativeSwitchboard_;
        emit UpdatedRemoteNativeSwitchboard(remoteNativeSwitchboard_);
    }

    /**
     * @notice Allows the withdrawal of fees by the account with the specified address.
     * @param account_ The address of the account to withdraw fees to.
     * @dev The caller must have the WITHDRAW_ROLE.
     */
    function withdrawFees(address account_) external onlyRole(WITHDRAW_ROLE) {
        FeesHelper.withdrawFees(account_);
    }

    /**
     * @notice Rescues funds from a contract that has lost access to them.
     * @param token_ The address of the token contract.
     * @param userAddress_ The address of the user who lost access to the funds.
     * @param amount_ The amount of tokens to be rescued.
     */
    function rescueFunds(
        address token_,
        address userAddress_,
        uint256 amount_
    ) external onlyRole(RESCUE_ROLE) {
        RescueFundsLib.rescueFunds(token_, userAddress_, amount_);
    }
}
