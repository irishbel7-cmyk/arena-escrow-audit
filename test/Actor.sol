// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Per-identity proxy so tests can act as distinct addresses without forge-std cheatcodes.
contract Actor {
    IERC20 public usdc;
    address public esc;
    address public me;

    constructor(address who, IERC20 token_, address esc_) {
        me = who;
        usdc = token_;
        esc = esc_;
    }

    function _pull() internal {
        // move minted funds onto this actor (owner mints to this contract in tests)
    }

    function fundAg(address agent, uint256 amount, uint256 deadline) external returns (uint256) {
        // fund from this contract's balance as poster
        IERC20(esc_token()).approve(esc, amount);
        return BountyEscrowCall().fund(agent, amount, deadline, keccak256("r"));
    }

    function tryFund(address agent, uint256 amount, uint256 deadline) external returns (bool ok) {
        IERC20(esc_token()).approve(esc, amount);
        (ok, ) = esc.call(abi.encodeWithSignature("fund(address,uint256,uint256,bytes32)", agent, amount, deadline, keccak256("r")));
    }

    function tryReject(uint256 id) external returns (bool ok) {
        (ok, ) = esc.call(abi.encodeWithSignature("reject(uint256)", id));
    }

    function complete(uint256 id) external {
        (bool ok, ) = esc.call(abi.encodeWithSignature("complete(uint256)", id));
        require(ok, "complete failed");
    }

    function submit(uint256 id, bytes32 h) external {
        (bool ok, ) = esc.call(abi.encodeWithSignature("submit(uint256,bytes32)", id, h));
        require(ok, "submit failed");
    }

    function abandon(uint256 id) external {
        (bool ok, ) = esc.call(abi.encodeWithSignature("abandon(uint256)", id));
        require(ok, "abandon failed");
    }

    function esc_token() internal view returns (address) { return address(usdc); }
    function BountyEscrowCall() internal view returns (BountyEscrowRaw) { return BountyEscrowRaw(esc); }
}

interface BountyEscrowRaw {
    function fund(address agent, uint256 amount, uint256 deadline, bytes32 ref) external returns (uint256);
}
