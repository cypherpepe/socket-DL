// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

abstract contract IAccumulator {
    bytes32 public SOCKET_ROLE = keccak256("SOCKET_ROLE");

    event SocketSet(address indexed socket);
    event MessageAdded(bytes32 packedMessage, bytes32 newRootHash);
    event PacketComplete(bytes32 rootHash, uint256 packetId);

    // caller only Socket
    function addMessage(bytes32 packedMessage) external virtual;

    function getNextPacket() external view virtual returns (bytes32, uint256);

    function getRootById(uint256 id) external view virtual returns (bytes32);

    // caller only Socket
    function sealPacket() external virtual returns (bytes32, uint256);
}