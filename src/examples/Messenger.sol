// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.7;

import "../interfaces/IPlug.sol";
import "../interfaces/ISocket.sol";

contract Messenger is IPlug {
    // immutables
    address private immutable _socket;
    uint256 private immutable _chainSlug;

    address private _owner;
    bytes32 private _message;
    uint256 public msgGasLimit;

    bytes32 private constant _PING = keccak256("PING");
    bytes32 private constant _PONG = keccak256("PONG");

    constructor(
        address socket_,
        uint256 chainSlug_,
        uint256 msgGasLimit_
    ) {
        _socket = socket_;
        _chainSlug = chainSlug_;
        _owner = msg.sender;

        msgGasLimit = msgGasLimit_;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "can only be called by owner");
        _;
    }

    function sendLocalMessage(bytes32 message_) external {
        _updateMessage(message_);
    }

    function sendRemoteMessage(uint256 remoteChainSlug_, bytes32 message_)
        external
        payable
    {
        bytes memory payload = abi.encode(_chainSlug, message_);
        _outbound(remoteChainSlug_, payload);
    }

    function inbound(bytes calldata payload_) external payable override {
        require(msg.sender == _socket, "Counter: Invalid Socket");
        (uint256 localChainSlug, bytes32 msgDecoded) = abi.decode(
            payload_,
            (uint256, bytes32)
        );

        _updateMessage(msgDecoded);

        bytes memory newPayload = abi.encode(
            _chainSlug,
            msgDecoded == _PING ? _PONG : _PING
        );
        _outbound(localChainSlug, newPayload);
    }

    // settings
    function setSocketConfig(
        uint256 remoteChainSlug,
        address remotePlug,
        string calldata integrationType
    ) external onlyOwner {
        ISocket(_socket).setPlugConfig(
            remoteChainSlug,
            remotePlug,
            integrationType
        );
    }

    function message() external view returns (bytes32) {
        return _message;
    }

    function _updateMessage(bytes32 message_) private {
        _message = message_;
    }

    function _outbound(uint256 targetChain_, bytes memory payload_) private {
        ISocket(_socket).outbound{value: msg.value}(
            targetChain_,
            msgGasLimit,
            payload_
        );
    }
}