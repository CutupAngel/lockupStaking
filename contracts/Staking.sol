//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./TokenStakeOwnable.sol";
import "./FarmCoin.sol";

import "hardhat/console.sol";

enum DepositeType {
    Immediate,
    ShortTerm,
    LongTerm
}

/// @notice one user staking information (amount, end time)
struct StakeInfo {
    address stakeToken;
    address rewardToken;
    uint256 amount;
    uint256 rewards;
    uint64 start;
    uint64 end;
    uint64 lastClaimed;
}

/// @notice period option(period in days and total period bonus in percentage)
struct StakeOption {
    uint16 periodInDays;
    uint16 bonusInPercentage;
    address rewardToken;
    DepositeType depositeType;
}

/// @title Solo-staking token contract
/// @notice Staking token for one of pre-defined periods with different rewards and bonus percentage.
contract Staking is TokenStakeOwnable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    address private stakeTokenAddr;
    address private rewardTokenAddr;

    /// @notice store information about users stakes
    mapping(address => StakeInfo[]) public usersStake;

    /// @notice store information about users stakePair
    mapping(address => uint16) public stakePair;

    /// @notice store information about stake options
    mapping(address => StakeOption[]) public stakeOptions;

    /// @notice staked amount in for each option
    /// @dev stakeToken => reservedAmount
    mapping(address => uint256) public totalReservedAmount;

    /// @notice emits on stake
    event Stake(
        address indexed sender,
        address indexed stakeToken,
        uint256 amount,
        uint16 option
    );

    /// @notice emits on token withdrawal from staking
    event Withdraw(
        address indexed sender,
        address indexed stakeToken,
        address indexed rewardToken,
        uint256 amount,
        uint256 rewards
    );

    /// @notice emits when option for stake token is changed
    event OptionChange(address indexed stakeToken, uint16 indexed option);

    /// @notice emits when new option for stake token is created
    event OptionAdd(address indexed stakeToken, uint16 indexed newOption);

    /// @dev Check for value is greater then zero
    modifier gtZero(uint256 value) {
        require(value > 0, "value == 0");
        _;
    }

    /// @dev Checks that selected stake option is valid
    modifier validOption(address stakeToken, uint16 option) {
        require(stakeToken == stakeTokenAddr, "Not USDC!");
        require(option < stakeOptions[stakeToken].length, "!option");
        require(
            stakeOptions[stakeToken][option].periodInDays != 0 &&
                stakeOptions[stakeToken][option].bonusInPercentage != 0 &&
                stakeOptions[stakeToken][option].rewardToken != address(0) &&
                stakeOptions[stakeToken][option].rewardToken == rewardTokenAddr,
            "!active option"
        );
        _;
    }

    constructor(address _stakeToken, address _rewardToken) {
        stakeTokenAddr = _stakeToken;
        rewardTokenAddr = _rewardToken;
    }

    /// @notice puts tokens into staking for given option
    /// @param amount - amount of tokens to put into stake,
    /// @param option - index of the option in stakeOptions array
    function stake(
        address stakeToken,
        uint256 amount,
        uint16 option
    ) external gtZero(amount) {
        IERC20(stakeToken).safeTransferFrom(
            _msgSender(),
            address(this),
            amount
        );
        _stake(_msgSender(), stakeToken, amount, option);
    }

    /// @dev internal function for stake logic implementation (without transfer tokens)
    /// @param amount - amount of tokens,
    /// @param option - index of the option in stakeOptions mapping
    /// @param account - address of user account
    function _stake(
        address account,
        address stakeToken,
        uint256 amount,
        uint16 option
    )
        internal
        nonReentrant
        validOption(stakeToken, option)
        whenStakingNotPaused(stakeToken)
    {
        require(account != address(0), "!account");
        StakeOption memory opt = stakeOptions[stakeToken][option];

        stakePair[_msgSender()] = option;
        uint256 rewards = calculateRewards(stakeToken, amount, option);

        require(
            IERC20(opt.rewardToken).balanceOf(address(this)) >=
                rewards + amount,
            "!reserves"
        );

        usersStake[account].push(
            StakeInfo({
                stakeToken: stakeToken,
                rewardToken: opt.rewardToken,
                amount: amount,
                rewards: rewards,
                start: uint64(block.timestamp),
                end: uint64(block.timestamp + opt.periodInDays * 1 days),
                lastClaimed: uint64(block.timestamp)
            })
        );

        totalReservedAmount[stakeToken] += amount;
        totalReservedAmount[opt.rewardToken] += rewards;

        emit Stake(account, stakeToken, amount, option);
    }

    /// @notice withdraw tokens
    /// @param stakeToken - stake token
    /// @param stakeIndex - index of user`s stake
    function withdraw(address stakeToken, uint16 stakeIndex)
        external
        nonReentrant
    {
        require(usersStake[_msgSender()].length > stakeIndex, "!index");

        StakeInfo memory s = usersStake[_msgSender()][stakeIndex];
        StakeOption memory o = stakeOptions[stakeToken][
            stakePair[_msgSender()]
        ];

        require(s.stakeToken == stakeToken, "!stakeToken");
        require(block.timestamp > s.end, "!end");
        require(
            isClaimable(_msgSender(), stakeToken, stakeIndex),
            "Not claimable"
        );

        // remove stake from user stakes
        usersStake[_msgSender()][stakeIndex] = usersStake[_msgSender()][
            usersStake[_msgSender()].length - 1
        ];

        usersStake[_msgSender()].pop();

        totalReservedAmount[stakeToken] -= s.amount;
        totalReservedAmount[s.rewardToken] -= s.rewards;

        // calc the fee if withdraw immediately
        if (
            o.depositeType != DepositeType.Immediate &&
            s.start + 1 weeks * 24 < block.timestamp
        ) {
            IERC20(stakeToken).safeTransfer(
                _msgSender(),
                (s.amount - s.amount / 10)
            );
            IERC20(stakeToken).safeTransfer(address(this), s.amount / 10);
            IERC20(s.rewardToken).safeTransfer(_msgSender(), s.rewards);
        } else {
            IERC20(stakeToken).safeTransfer(_msgSender(), s.amount);
            IERC20(s.rewardToken).safeTransfer(_msgSender(), s.rewards);
        }

        emit Withdraw(
            _msgSender(),
            stakeToken,
            s.rewardToken,
            s.amount,
            s.rewards
        );
    }

    function isClaimable(
        address account,
        address stakeToken,
        uint16 stakeIndex
    ) internal view returns (bool retVal) {
        StakeInfo memory s = usersStake[_msgSender()][stakeIndex];
        StakeOption memory o = stakeOptions[stakeToken][
            stakePair[_msgSender()]
        ];
        calculateRewards(stakeToken, s.amount, stakePair[account]);
        s.lastClaimed = uint64(block.timestamp);
        retVal = true;
        if (o.depositeType == DepositeType.Immediate) {
            retVal = s.end < uint64(block.timestamp);
        } else if (o.depositeType == DepositeType.ShortTerm) {
            retVal = (s.lastClaimed + 1 weeks * 24) < uint64(block.timestamp);
        } else if (o.depositeType == DepositeType.ShortTerm) {
            retVal = (s.lastClaimed + 1 weeks * 52) < uint64(block.timestamp);
        }
    }

    function claimRewards(uint16 stakeIndex) external {
        require(usersStake[_msgSender()].length > stakeIndex, "!index");
        require(
            isClaimable(_msgSender(), stakeTokenAddr, stakeIndex),
            "Not claimable"
        );
        StakeInfo memory _userStake = usersStake[_msgSender()][stakeIndex];
        require(_userStake.rewards > 0, "claim: !rewards");
        totalReservedAmount[_userStake.rewardToken] -= _userStake.rewards;
        IERC20(_userStake.rewardToken).safeTransfer(
            _msgSender(),
            _userStake.rewards
        );
    }

    /// @notice add new option
    /// @param token - stake token
    /// @param period - period for options
    /// @param bonusInPercentage - bonuse for each option in percents (100 = 1%)
    function addStakeOptions(
        address token,
        uint16 period,
        uint16 bonusInPercentage,
        address rewardToken,
        DepositeType depositeType
    ) external onlyTokenStakeOwner(token) {
        require(token == stakeTokenAddr, "!Not USDC");
        stakeOptions[token].push(
            StakeOption(period, bonusInPercentage, rewardToken, depositeType)
        );
        emit OptionAdd(token, uint16(stakeOptions[token].length) - 1);
    }

    /// @notice returns all user stakes
    function getUserStakes(address account)
        external
        view
        returns (StakeInfo[] memory)
    {
        return usersStake[account];
    }

    /// @notice return stake options array
    function getStakeOptions(address stakeToken)
        external
        view
        returns (StakeOption[] memory)
    {
        return stakeOptions[stakeToken];
    }

    /// @notice calculate user stake rewards
    function calculateRewards(
        address stakeToken,
        uint256 amount,
        uint16 optionIndex
    ) public view returns (uint256) {
        return
            stakeOptions[stakeToken][optionIndex].depositeType ==
                DepositeType.Immediate
                ? amount / 10
                : stakeOptions[stakeToken][optionIndex].depositeType ==
                    DepositeType.ShortTerm
                ? amount / 5
                : (amount * 10) / 3;
    }

    /// @notice returns how many tokens free
    function notReservedTokenAmount(address token)
        public
        view
        returns (uint256)
    {
        return
            IERC20(token).balanceOf(address(this)) - totalReservedAmount[token];
    }
}
