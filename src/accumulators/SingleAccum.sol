// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.7;

import "./BaseAccum.sol";

contract SingleAccum is BaseAccum {
    /**
     * @notice initialises the contract with socket and notary addresses
     */
    constructor(
        address socket_,
        address notary_,
        uint32 remoteChainSlug_
    ) BaseAccum(socket_, notary_, remoteChainSlug_) {}

    /// adds the packed message to a packet
    /// @inheritdoc IAccumulator
    function addPackedMessage(bytes32 packedMessage)
        external
        override
        onlyRole(SOCKET_ROLE)
    {
        uint256 packetId = _packets;
        _roots[packetId] = packedMessage;
        _packets++;

        emit MessageAdded(packedMessage, packetId, packedMessage);
    }
}