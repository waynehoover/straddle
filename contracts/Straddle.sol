

// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Straddle is Context, Ownable, ERC20("Straddle", "STRAD") {

    uint constant YEAR_3000 = 32503680000;
    uint constant MAX_SUPPLY = 10_000_000;

    // USDC: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Tracks the deposited USDC pending the next round of reward distribution.
    uint public stagingPoolSizeUsdc;

    struct Distribution {
      uint time;
      uint rewardAmount;
      uint stakedTotal;
    }
    Distribution[] distributions;

    struct Lock {
      uint startTime;
      uint endTime;
      uint stakedAmount;
      uint tier; // 0 - 4
    }
    mapping(address => Lock[]) userLocks;

    struct Account {
        // The total STRAD an account has in deposit.
        uint depositBalance;
    }
    mapping(address => Account) userAccounts;

    constructor() {
        _mint(msg.sender, MAX_SUPPLY);
    }

    function depositRewards(uint usdcAmount) public {
        // Requires ERC-20 approval
        USDC.transferFrom(msg.sender, address(this), usdcAmount);
        stagingPoolSizeUsdc += usdcAmount;
    }

    function distributeRewards() public onlyOwner {
        // The staked total is used to compute the rewards per user.
        // as to how the stakedTotal allows for correct reward distribution when it does not
        // take into account time-lock weights, let me explain:
        // - tier-0 locks get created upon deposit w/ or w/o an actual time component to the lock. 
        // - tier-0 lock is just staking to the contract. withdrawable at any point. 
        // - tier-0 results in 50% of the reward pool by stake weight against stakedTotal
        // - tier-2 lock results in additional 20% of reward pool by stake weight against stakedTotal
        // - therefore by separating the lock tiers & combining the reward rates, 
        //     we don't have to weight the quotient of stake/stakedTotal.
        
        // Contract's STRAD balance ie. total deposited/staked/locked STRAD
        uint stakedTotal = balanceOf(address(this));

        // Add a distribution to the (immutable?) record of distributions
        distributions.push(Distribution(block.timestamp, stagingPoolSizeUsdc, stakedTotal));
        stagingPoolSizeUsdc = 0;
    }

    function deposit(uint amount, uint lock_tier) public {
        require(lock_tier <= 4, "Invalid Lock Tier.");

        // transfer here requires erc20 approval
        _transfer(msg.sender, address(this), amount);
        userAccounts[msg.sender].depositBalance += amount;

        // create a "lock" for the base reward (tier 0)
        // this is not time-locked but reflects a deposit/stake
        _lock(amount, 0);

        if (lock_tier > 0) {
            _lock(amount, lock_tier);
        }
    }

    function createLock(uint amount, uint tier) public {
        _lock(amount, tier);
    }

    function _lock(uint amount, uint lockTier) internal {
        uint deposited = getUserDepositBalance(msg.sender);
        uint locked = getUserLockedBalance(msg.sender);
        uint unlocked = deposited - locked;

        require(amount <= unlocked, "attempted lock amount exceeds deposits available for locking");

        uint unlock_at = block.timestamp + (lockTier * 12 weeks);
        Lock memory lock = Lock(block.timestamp, unlock_at, amount, lockTier);
        userLocks[msg.sender].push(lock);
    }

    function getDistributions() public view returns (Distribution[] memory) {
        return distributions;
    }

    function getUsersLocks(address user) public view returns (Lock[] memory) {
        return userLocks[user];
    }

    function getUserDepositBalance(address user) public view returns (uint) {
        return userAccounts[user].depositBalance;
    }

    function _lockIsActive(Lock storage lock) internal view returns (bool) {
        if (block.timestamp < lock.endTime && lock.tier > 0) {
            return true;
        }
        return false;
    }

    function getUserLockedBalance(address user) public view returns (uint) {
        uint lockedBalance = 0;

        for (uint i = 0; i < userLocks[user].length; i++) {
            Lock storage lock = userLocks[user][i];
            if (_lockIsActive(lock)) {
                lockedBalance += lock.stakedAmount;
            }
        }

        return lockedBalance;
    }

    function calculateRewards(address user) public view returns (uint) {
        uint totalReward = 0;
        for (uint i = 0; i < userLocks[user].length; i++) {

            Lock memory lock = userLocks[user][i];
            uint totalDistributionsEmittedDuringThisLock = 0;

            for (uint j = 0; j < distributions.length; j++) {
                Distribution memory distribution = distributions[j];

                if (distribution.time >= lock.startTime && distribution.time <= lock.endTime) {
                    // Summing the quotients of rewards distributed and total staked at distribution
                    // for each distribution during the lock.
                    // This is the mathematical implementation of the concept in
                    // Scalable Reward Distribution on the Ethereum Blockchain; Botag, Boca, and Johnson
                    // https://uploads-ssl.webflow.com/5ad71ffeb79acc67c8bcdaba/5ad8d1193a40977462982470_scalable-reward-distribution-paper.pdf
                    totalDistributionsEmittedDuringThisLock += distribution.rewardAmount / distribution.stakedTotal;
                }
            }

            totalReward += lock.stakedAmount * totalDistributionsEmittedDuringThisLock;
        }

        return totalReward;
    }

    function withdraw(uint amount) public {
        uint deposited = getUserDepositBalance(msg.sender);
        uint locked = getUserLockedBalance(msg.sender);
        require(deposited > 0, "No funds to withdraw");

        uint availableToWithdraw = deposited - locked;
        require(availableToWithdraw > 0, "No unlocked funds available to withdraw");
        require(availableToWithdraw >= amount, "Amount to withdraw exceeds available funds");

        userAccounts[msg.sender].depositBalance -= amount;
        _transfer(address(this), msg.sender, amount);
    }
}
