// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "./library/Math.sol";
import "./utils/SafeBEP20.sol";
import "./access/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./eZKaliburProxy.sol";
import "./library/Whitelist.sol";
import "./interfaces/IMeerkatReferral.sol";
import "./interfaces/IERC721.sol";

interface IMeerkatToken {
    function mint(address _to, uint256 _amount) external returns (bool);
    function redeem(uint256 _amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface NFTController {
    function getBoostRate(address token, uint tokenId) external view returns (uint boostRate);
    function isWhitelistedNFT(address token) external view returns (bool);
}

interface GaugeController {
    function getBoostRate(address sender, uint pid) external view returns (uint boostRate);
}

contract eZKaliburMaster is Ownable, ReentrancyGuard, Whitelist {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Bonus muliplier for early meerkat makers.
    uint256 public constant BONUS_MULTIPLIER = 1;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. MMF to distribute per block.
        uint256 lastRewardBlock;  // Last block number that MMF distribution occurs.
        uint256 accMeerkatPerShare;   // Accumulated MMF per share, times 1e18. See below.
    }

    struct NFTSlot {
        address slot1;
        uint256 tokenId1;
        address slot2;
        uint256 tokenId2;
        address slot3;
        uint256 tokenId3;
    }

    // The MMF TOKEN!
    IMeerkatToken public xMeerkat;
    IMeerkatToken public meerkat;
    // MMF tokens created per block.
    uint256 public meerkatPerBlock;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;
    // The block number when MMF mining starts.
    uint256 public startBlock;

    mapping(IBEP20 => bool) public poolExistence;
    mapping(address => mapping(uint256 => NFTSlot)) private _depositedNFT; // user => pid => nft slot;

    bool public whitelistAll;
    NFTController public controller = NFTController(address(0));
    uint public nftBoostRate = 100;

    // Meerkat referral contract address.
    IMeerkatReferral public meerkatReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 100; // 1%
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;
    // Proxy to hold MMF
    eZKaliburProxy public proxy = eZKaliburProxy(0xA196f542c44057dBA571a2cfb24A9cd37e628306);

    // Unlock rate
    uint16 public unlockRate = 2000; // 10%

    GaugeController public gauge = GaugeController(address(0));

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UpdateEmissionRate(address indexed user, uint256 meerkatPerBlock);
    event UpdateNFTController(address indexed user, address controller);
    event UpdateGaugeController(address indexed user, address controller);
    event UpdateNFTBoostRate(address indexed user, uint256 controller);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor(
        IMeerkatToken _xMeerkat,
        IMeerkatToken _meerkat,
        uint256 _meerkatPerBlock,
        uint256 _startBlock
    ) public {
        xMeerkat = _xMeerkat;
        meerkat = _meerkat;
        meerkatPerBlock = _meerkatPerBlock;
        startBlock = _startBlock;
        totalAllocPoint = 0;
        whitelistAll = false;
    }

    /* ========== Modifiers ========== */

    modifier nonDuplicated(IBEP20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    modifier nonContract() {
        if (!isWhitelist(msg.sender) && !whitelistAll) {
            require(tx.origin == msg.sender);
        }
        _;
    }

    /* ========== NFT View Functions ========== */

    function getBoost(address _account, uint256 _pid) public view returns (uint256) {
        if (address(controller) == address(0)) return 0;
        NFTSlot memory slot = _depositedNFT[_account][_pid];
        uint boost1 = controller.getBoostRate(slot.slot1, slot.tokenId1);
        uint boost2 = controller.getBoostRate(slot.slot2, slot.tokenId2);
        uint boost3 = controller.getBoostRate(slot.slot3, slot.tokenId3);
        uint boost = boost1 + boost2 + boost3;
        return boost.mul(nftBoostRate).div(100); // boosts from 0% onwards
    }

    function getBoostGauge(address _account, uint256 _pid) public view returns (uint256) {
        if (address(gauge) == address(0)) return 0; // 10000 equals 1%, 5BPs
        return gauge.getBoostRate(_account, _pid); // boosts from 0% onwards
    }

    function getSlots(address _account, uint256 _pid) public view returns (address, address, address) {
        NFTSlot memory slot = _depositedNFT[_account][_pid];
        return (slot.slot1, slot.slot2, slot.slot3);
    }

    function getTokenIds(address _account, uint256 _pid) public view returns (uint256, uint256, uint256) {
        NFTSlot memory slot = _depositedNFT[_account][_pid];
        return (slot.tokenId1, slot.tokenId2, slot.tokenId3);
    }

    /* ========== View Functions ========== */

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending MMF on frontend.
    function pendingMeerkat(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMeerkatPerShare = pool.accMeerkatPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 meerkatReward = multiplier.mul(meerkatPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accMeerkatPerShare = accMeerkatPerShare.add(meerkatReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accMeerkatPerShare).div(1e18).sub(user.rewardDebt);
    }

    /* ========== Owner Functions ========== */

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IBEP20 _lpToken, bool _withUpdate) public onlyOwner nonDuplicated(_lpToken) {
        require(_lpToken.balanceOf(address(this)) >= 0, "Not ERC20");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : lastRewardBlock,
            accMeerkatPerShare : 0
        }));
    }

    // Update the given pool's MMF allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Sets multiple lpToken in 1 txn
    function multiSet(uint256[] calldata _pids, uint256[] calldata _allocPoints, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        for (uint i = 0; i < _pids.length; ++i) {
            set(_pids[i], _allocPoints[i], false);
        }
    }

    /* ========== NFT External Functions ========== */

    // Depositing of NFTs
    function depositNFT(address _nft, uint256 _tokenId, uint256 _slot, uint256 _pid) public nonContract {
        require(controller.isWhitelistedNFT(_nft), "only approved NFTs");
        require(ERC721(_nft).balanceOf(msg.sender) > 0, "user does not have specified NFT");
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount == 0, "not allowed to deposit");
        
        ERC721(_nft).transferFrom(msg.sender, address(this), _tokenId);
        
        NFTSlot memory slot = _depositedNFT[msg.sender][_pid];

        if (_slot == 1) slot.slot1 = _nft;
        else if (_slot == 2) slot.slot2 = _nft;
        else if (_slot == 3) slot.slot3 = _nft;
        
        if (_slot == 1) slot.tokenId1 = _tokenId;
        else if (_slot == 2) slot.tokenId2 = _tokenId;
        else if (_slot == 3) slot.tokenId3 = _tokenId;

        _depositedNFT[msg.sender][_pid] = slot;
    }

    // Withdrawing of NFTs
    function withdrawNFT(uint256 _slot, uint256 _pid) public nonContract {
        address _nft;
        uint256 _tokenId;
        
        NFTSlot memory slot = _depositedNFT[msg.sender][_pid];

        if (_slot == 1) _nft = slot.slot1;
        else if (_slot == 2) _nft = slot.slot2;
        else if (_slot == 3) _nft = slot.slot3;
        
        if (_slot == 1) _tokenId = slot.tokenId1;
        else if (_slot == 2) _tokenId = slot.tokenId2;
        else if (_slot == 3) _tokenId = slot.tokenId3;

        if (_slot == 1) slot.slot1 = address(0);
        else if (_slot == 2) slot.slot2 = address(0);
        else if (_slot == 3) slot.slot3 = address(0);
        
        if (_slot == 1) slot.tokenId1 = uint(0);
        else if (_slot == 2) slot.tokenId2 = uint(0);
        else if (_slot == 3) slot.tokenId3 = uint(0);

        _depositedNFT[msg.sender][_pid] = slot;
        
        ERC721(_nft).transferFrom(address(this), msg.sender, _tokenId);
    }

    /* ========== External Functions ========== */

    // Update reward variables for all pools. Be careful of gas spending!
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
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 meerkatReward = multiplier.mul(meerkatPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        xMeerkat.mint(address(proxy), meerkatReward);

        pool.accMeerkatPerShare = pool.accMeerkatPerShare.add(meerkatReward.mul(1e18).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for MMF allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public nonReentrant nonContract {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (_amount > 0 && address(meerkatReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            meerkatReferral.recordReferral(msg.sender, _referrer);
        }
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accMeerkatPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                safeMeerkatTransfer(msg.sender, pending, _pid);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMeerkatPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant nonContract {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accMeerkatPerShare).div(1e18).sub(user.rewardDebt);
        if (pending > 0) {
            safeMeerkatTransfer(msg.sender, pending, _pid);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accMeerkatPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe MMF transfer function, just in case if rounding error causes pool to not have enough MMF.
    function safeMeerkatTransfer(address _to, uint256 _amount, uint256 _pid) internal {
        uint256 boost = 0;

        // retrieves xMMF tokens
        _amount = proxy.safeMeerkatTransfer(address(this), _amount);
        uint unlockedAmt = _amount.mul(unlockRate).div(10000);
        
        // redeems portion of xMMF tokens
        xMeerkat.redeem(unlockedAmt);
        meerkat.transfer(_to, unlockedAmt);
        xMeerkat.transfer(_to, _amount.sub(unlockedAmt));
 
        boost = getBoost(_to, _pid).mul(_amount).div(100);
        boost = boost.add(getBoostGauge(_to, _pid).mul(_amount).div(10000));
        payReferralCommission(msg.sender, _amount);
        if (boost > 0) meerkat.mint(_to, boost);
    }

    /* ========== Set Variable Functions ========== */

    function updateEmissionRate(uint256 _meerkatPerBlock) public onlyOwner {
        massUpdatePools();
        meerkatPerBlock = _meerkatPerBlock;
        emit UpdateEmissionRate(msg.sender, _meerkatPerBlock);
    }

    function setNftController(address _controller) public onlyOwner {
        controller = NFTController(_controller);
        emit UpdateNFTController(msg.sender, _controller);
    }

    function setGaugeController(address _controller) public onlyOwner {
        gauge = GaugeController(_controller);
        emit UpdateGaugeController(msg.sender, _controller);
    }

    function setNftBoostRate(uint256 _rate) public onlyOwner {
        require(_rate > 50 && _rate < 500, "boost must be within range");
        nftBoostRate = _rate;
        emit UpdateNFTBoostRate(msg.sender, _rate);
    }

    function setMeerkatReferral(IMeerkatReferral _meerkatReferral) public onlyOwner {
        meerkatReferral = _meerkatReferral;
    }
    
    function flipWhitelistAll() public onlyOwner {
        whitelistAll = !whitelistAll;
    }

    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }
    
    function setUnlockRate(uint16 _unlockRate) public onlyOwner {
        require(_unlockRate <= 10000, "setUnlockRate: invalid unlock rate basis points");
        unlockRate = _unlockRate;
    }
    
    function setProxy(address _proxy) public onlyOwner {
        require(_proxy != address(0), "setProxy: invalid proxy");
        proxy = eZKaliburProxy(_proxy);
    }

    /* ========== Internal Functions ========== */

    // Pay referral commission to the referrer who referred this user
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(meerkatReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = meerkatReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                meerkat.mint(referrer, commissionAmount);
                meerkatReferral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }
}