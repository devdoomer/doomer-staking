pragma solidity 0.6.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Doomer.sol";

contract RewardsPool is Ownable {
    using SafeERC20 for Doomer;

    Doomer public doomer;

    uint256 constant MAX_INT = uint256(2**256 - 1);

    constructor (Doomer _doomer) public {
        doomer = _doomer;
    }

    function approveRewardDistribution(address rewardDistributor) public onlyOwner {
        doomer.approve(rewardDistributor, MAX_INT);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() public onlyOwner {
        uint256 balance = doomer.balanceOf(address(this));
        doomer.safeTransfer(owner(), balance);
    }
}