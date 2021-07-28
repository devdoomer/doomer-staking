pragma solidity 0.6.6;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "./ERC1155Receiver.sol";
import "./DoomerTicket.sol";
import "./Doomer.sol";

// CREDIT TO DOOMERSWAP FOR THIS CONTRACT!
//
// DoomerChef is the master Doomer. He can make microawaved pizzas all day and he is a depressed guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once The Doomer Collective is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract DoomerERC1155Chef is Ownable, ERC1155Receiver {
    using SafeMath for uint256;
    using SafeERC20 for Doomer;
    using EnumerableSet for EnumerableSet.UintSet;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many ERC1155 tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lastTicketRewardBlock;
        //
        // We do some fancy math here. Basically, any point in time, the amount of DOOMERs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accDoomerPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accDoomerPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC1155 nftToken;           // Address of LP token contract.
        uint256 tokensStaked;
        uint256 allocPoint;       // How many allocation points assigned to this pool. DOOMERs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that DOOMERs distribution occurs.
        uint256 accDoomerPerShare; // Accumulated DOOMERs per share, times 1e12. See below.
        uint256 ticketsPerBlock; // Doomer tickets per block for joining a pool.
        bool rewardsPaused; // If true, rewards will no longer be accumulated in the pool.
    }

    struct UserStake {
        mapping (uint256 => uint256) balances;
        EnumerableSet.UintSet userTokens;
    }

    // Doomer ticket manager.
    DoomerTicket doomerTickets;

    // Pool of rewards.
    address public rewardsPool;
    // The DOOMER TOKEN!
    Doomer public doomer;
    // DOOMER tokens created per block.
    uint256 public doomerPerBlock;
    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    mapping (uint256 => mapping (address => UserStake)) userStake;

    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when DOOMER mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        Doomer _doomer,
        address _rewardsPool,
        uint256 _doomerPerBlock,
        uint256 _startBlock,
        DoomerTicket _doomerTickets
    ) public {
        doomer = _doomer;
        rewardsPool = _rewardsPool;
        doomerPerBlock = _doomerPerBlock;
        startBlock = _startBlock;
        doomerTickets = _doomerTickets;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getStakedTokens(uint256 _pid, address user) external view returns (uint256[] memory) {
        uint256[] memory tokens;
        
        UserStake storage uStake = userStake[_pid][msg.sender];
        for (uint256 i = 0; i < uStake.userTokens.length(); i++) {
            tokens[i] = uStake.userTokens.at(i);
        }
        return tokens;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, uint256 _ticketsPerBlock,  IERC1155 _nftToken, bool _rewardsPaused, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            nftToken: _nftToken,
            tokensStaked: 0,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accDoomerPerShare: 0,
            ticketsPerBlock: _ticketsPerBlock,
            rewardsPaused: _rewardsPaused
        }));
    }

    // Update the given pool's DOOMER allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint256 _ticketsPerBlock, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].ticketsPerBlock = _ticketsPerBlock;
    }

    
    // Enables or disables rewards.
    function setRewards(uint256 _pid, bool _rewardsPaused) public onlyOwner {
        // Update pool to distribute remaining rewards when pausing.
        // Also updates last reward block if enabling rewards again, so
        // rewards resume from the point of calling this method.
        updatePool(_pid);
        poolInfo[_pid].rewardsPaused = _rewardsPaused;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to, uint256 _pid) public view returns (uint256) {
        if (poolInfo[_pid].rewardsPaused) {
            return 0;
        }
        return _to.sub(_from);
    }
    // View function to see pending DOOMERs on frontend.
    function pendingDoomer(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accDoomerPerShare = pool.accDoomerPerShare;
        uint256 nftSupply = pool.tokensStaked;
        if (block.number > pool.lastRewardBlock && nftSupply != 0  && user.amount > 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number, _pid);
            uint256 doomerReward = multiplier.mul(doomerPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accDoomerPerShare = accDoomerPerShare.add(doomerReward.mul(1e12).div(nftSupply));
        }
        return user.amount.mul(accDoomerPerShare).div(1e12).sub(user.rewardDebt);
    }

    function pendingTickets(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 nftSupply = pool.tokensStaked;
        if (block.number > user.lastTicketRewardBlock && nftSupply != 0 && user.amount > 0) {
            uint256 multiplier = getMultiplier(user.lastTicketRewardBlock, block.number, _pid);
            uint256 ticketReward = multiplier.mul(pool.ticketsPerBlock);
            if (ticketReward >= doomerTickets.TICKET_CAP()) {
                return doomerTickets.TICKET_CAP();
            }
            return ticketReward;
        }
        return 0;
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 nftSupply = pool.tokensStaked;
        if (nftSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number, _pid);
        uint256 doomerReward = multiplier.mul(doomerPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accDoomerPerShare = pool.accDoomerPerShare.add(doomerReward.mul(1e12).div(nftSupply));
        pool.lastRewardBlock = block.number;
    }

    function claim(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accDoomerPerShare).div(1e12).sub(user.rewardDebt);
            safeDoomerTransfer(msg.sender, pending);
        }
        user.rewardDebt = user.amount.mul(pool.accDoomerPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, 0);
    }

    // Deposit LP tokens to MasterChef for DOOMER allocation.
    function deposit(uint256 _pid, uint256 _tokenId, uint256 amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        UserStake storage uStake = userStake[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            // Doomer rewards.
            uint256 pending = user.amount.mul(pool.accDoomerPerShare).div(1e12).sub(user.rewardDebt);
            safeDoomerTransfer(msg.sender, pending);

            // Tickets rewards.
            uint256 pendingTicketRewards = pendingTickets(_pid, msg.sender);
            doomerTickets.mintTickets(msg.sender, pendingTicketRewards);
        }

        pool.nftToken.safeTransferFrom(address(msg.sender), address(this), _tokenId, amount, "");
        user.amount = user.amount.add(amount);
        uStake.balances[_tokenId] = uStake.balances[_tokenId].add(amount);
        pool.tokensStaked = pool.tokensStaked.add(amount);

        if (! uStake.userTokens.contains(_tokenId)) {
            uStake.userTokens.add(_tokenId);
        }

        user.rewardDebt = user.amount.mul(pool.accDoomerPerShare).div(1e12);
        user.lastTicketRewardBlock = block.number;

        emit Deposit(msg.sender, _pid, amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _tokenId, uint256 amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        UserStake storage userStake = userStake[_pid][msg.sender];
        require(userStake.balances[_tokenId] > 0, "user does not own the specified token id");
        require(user.amount >= amount, "withdraw: not good");
        updatePool(_pid);

        // Doomer rewards.
        uint256 pending = user.amount.mul(pool.accDoomerPerShare).div(1e12).sub(user.rewardDebt);
        safeDoomerTransfer(msg.sender, pending);

        // Tickets rewards.
        uint256 pendingTicketRewards = pendingTickets(_pid, msg.sender);
        doomerTickets.mintTickets(msg.sender, pendingTicketRewards);

        user.amount = user.amount.sub(amount);
        userStake.balances[_tokenId] = userStake.balances[_tokenId].sub(amount);
        pool.tokensStaked = pool.tokensStaked.sub(amount);

        if (userStake.balances[_tokenId] == 0) {
            userStake.userTokens.remove(_tokenId);
        }

        user.rewardDebt = user.amount.mul(pool.accDoomerPerShare).div(1e12);
        user.lastTicketRewardBlock = block.number;


        pool.nftToken.safeTransferFrom(address(this), address(msg.sender), _tokenId, amount, "");
        emit Withdraw(msg.sender, _pid, amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        UserStake storage userStake = userStake[_pid][msg.sender];

        for (uint256 i = userStake.userTokens.length() - 1; i >= 0 ; i--) {
            uint256 tokenId = userStake.userTokens.at(i);
            uint256 tokenBalance = userStake.balances[tokenId];
            pool.nftToken.safeTransferFrom(address(this), address(msg.sender), tokenId, tokenBalance, "");
            pool.tokensStaked = pool.tokensStaked.sub(tokenBalance);
            userStake.balances[tokenId] = 0;
            userStake.userTokens.remove(tokenId);
        }

        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe doomer transfer function, just in case if rounding error causes pool to not have enough DOOMERs.
    function safeDoomerTransfer(address _to, uint256 _amount) internal {
        uint256 doomerBal = doomer.balanceOf(rewardsPool);
        if (_amount > doomerBal) {
            doomer.safeTransferFrom(rewardsPool, _to, doomerBal);
        } else {
            doomer.safeTransferFrom(rewardsPool, _to, _amount);
        }
    }

    /**
	 * Set address of doomer ticket manager contract.
	 */
	function setDoomerTicket(address _doomerTickets) public onlyOwner {
		doomerTickets = DoomerTicket(_doomerTickets);
	}
}