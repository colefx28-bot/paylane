// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simulates a hostile/non-standard token (ERC777-style hook, or a
/// proxy-upgraded "USDC" with injected callback logic) that hijacks control
/// flow during transferFrom to attempt a reentrant call back into whatever
/// target/calldata is armed. Real USDC has no such hook, but the vault
/// should not be relying on that as its only line of defense — nonReentrant
/// must hold even against an adversarial token.
contract MaliciousReentrantToken is ERC20 {
    address public reentryTarget;
    bytes public reentryCalldata;
    bool public armed;

    constructor() ERC20("Malicious", "EVIL") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryCalldata = data;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false; // one-shot, avoid infinite recursion in the test itself
            (bool ok, ) = reentryTarget.call(reentryCalldata);
            // Intentionally ignore `ok` — we want to observe whether the
            // reentrant call reverted (it should, via ReentrancyGuard),
            // not have that revert bubble up and mask the outer call's
            // own success/failure in the test assertion.
        }
        return super.transferFrom(from, to, amount);
    }
}
