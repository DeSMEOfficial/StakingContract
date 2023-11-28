//SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IERC20EXT {
    function decimals() external view returns (uint8);
}

struct StructAccount {
    address selfAddress;
    uint256 totalValueStaked;
    uint256 stakingRewardsClaimed;
    uint256 pendingStakingRewards;
    uint256[] stakingIds;
}

struct StructStaking {
    bool isActive;
    address owner;
    uint256 stakingId;
    uint256 valueStaked;
    uint256 startTime;
    uint256 stakingRewardClaimed;
    uint256 initialRewards;
    uint256 calStartTime;
}

contract DesmeStaking is Ownable, Pausable {
    address[] private _users;
    uint256 private _totalStakingRewardsDistributed;

    uint256 private _stakingsCount;

    uint256 private _calStakingReward;
    uint256 private _valueStaked;

    uint256 private _lastTimeRewardDistributed;
    uint256 private _carryForwardBalance;

    address private _tokenAddress;

    bool private _noReentrancy;

    mapping(address => StructAccount) private _mappingAccounts;
    mapping(uint256 => StructStaking) private _mappingStakings;

    event SelfAddressUpdated(address newAddress);

    event Stake(uint256 value, uint256 stakingId);
    event UnStake(uint256 value);

    event ClaimedStakingReward(uint256 value);
    event DistributeStakingReward(uint256 value);

    event ContractPaused(bool isPaused);

    modifier noReentrancy() {
        require(!_noReentrancy, "Reentrancy attack.");
        _noReentrancy = true;
        _;
        _noReentrancy = false;
    }

    receive() external payable {
        distributeStakingRewards();
    }

    constructor(address initialOwner) Ownable(initialOwner) {
        uint256 currentTime = block.timestamp;
        _lastTimeRewardDistributed = currentTime;
    }

    function _updateUserAddress(
        StructAccount storage _userAccount,
        address _userAddress
    ) private {
        _userAccount.selfAddress = _userAddress;
        emit SelfAddressUpdated(_userAddress);
    }

    function _updateCalStakingReward(
        StructStaking storage stakingAccount,
        uint256 _value
    ) private {
        if (_calStakingReward > 0) {
            uint256 stakingReward = (_calStakingReward * _value) / _valueStaked;

            stakingAccount.initialRewards += stakingReward;
            _calStakingReward += stakingReward;
        }
    }

    function _stake(address _userAddress, uint256 _value) private {
        require(
            _userAddress != address(0),
            "_stake(): AddressZero cannot stake."
        );
        require(_value > 0, "_stake(): Value should be greater than zero.");

        StructAccount storage userAccount = _mappingAccounts[_userAddress];
        uint256 currentStakingId = _stakingsCount;

        if (userAccount.selfAddress == address(0)) {
            _updateUserAddress(userAccount, _userAddress);
            _users.push(_userAddress);
        }

        userAccount.stakingIds.push(currentStakingId);
        userAccount.totalValueStaked += _value;

        StructStaking storage stakingAccount = _mappingStakings[
            currentStakingId
        ];

        stakingAccount.isActive = true;
        stakingAccount.owner = _userAddress;
        stakingAccount.stakingId = currentStakingId;
        stakingAccount.valueStaked = _value;
        stakingAccount.startTime = block.timestamp;
        stakingAccount.calStartTime = _lastTimeRewardDistributed;

        _updateCalStakingReward(stakingAccount, _value);

        _valueStaked += _value;
        _stakingsCount++;

        emit Stake(_value, currentStakingId);
    }

    function stake(address _userAddress, uint256 _valueInWei)
        external
        whenNotPaused
    {
        bool sent = IERC20(_tokenAddress).transferFrom(
            msg.sender,
            address(this),
            _toTokens(_tokenAddress, _valueInWei)
        );

        require(sent, "unStake(): Tokens not transfered");

        _stake(_userAddress, _valueInWei);
    }

    function _getStakingRewardsById(StructStaking memory stakingAccount)
        private
        view
        returns (
            uint256 userStakingReward,
            uint256 rewardClaimable,
            uint256 carryForwardBalance
        )
    {
        if (
            _calStakingReward > 0 &&
            stakingAccount.isActive &&
            stakingAccount.calStartTime < _lastTimeRewardDistributed
        ) {
            userStakingReward =
                ((_calStakingReward * stakingAccount.valueStaked) /
                    _valueStaked) -
                (stakingAccount.stakingRewardClaimed +
                    stakingAccount.initialRewards);

            if (userStakingReward > 0) {
                carryForwardBalance = ((userStakingReward *
                    (stakingAccount.startTime - stakingAccount.calStartTime)) /
                    (_lastTimeRewardDistributed - stakingAccount.calStartTime));

                rewardClaimable = userStakingReward - carryForwardBalance;
            }
        }
    }

    function getStakingRewardsById(uint256 _stakingId)
        external
        view
        returns (
            uint256 userStakingReward,
            uint256 rewardClaimable,
            uint256 carryForwardBalance
        )
    {
        return _getStakingRewardsById(_mappingStakings[_stakingId]);
    }

    function _getUserAllStakingRewards(StructAccount memory userAccount)
        private
        view
        returns (
            uint256 userTotalStakingReward,
            uint256 totalRewardClaimable,
            uint256 totalCarryForwardBalance
        )
    {
        uint256[] memory userStakingIds = userAccount.stakingIds;

        for (uint256 i; i < userStakingIds.length; ++i) {
            StructStaking memory stakingAccount = _mappingStakings[
                userStakingIds[i]
            ];

            if (stakingAccount.isActive) {
                (
                    uint256 userStakingReward,
                    uint256 rewardClaimable,
                    uint256 carryForwardBalance
                ) = _getStakingRewardsById(stakingAccount);

                userTotalStakingReward += userStakingReward;
                totalRewardClaimable += rewardClaimable;
                totalCarryForwardBalance += carryForwardBalance;
            }
        }
    }

    function getUserStakingRewards(address _userAddress)
        external
        view
        returns (
            uint256 userTotalStakingReward,
            uint256 rewardClaimable,
            uint256 carryForwardBalance
        )
    {
        StructAccount memory userAccount = _mappingAccounts[_userAddress];

        return _getUserAllStakingRewards(userAccount);
    }

    function _claimUserStakingReward(address _userAddress)
        private
        returns (uint256 totalRewardClaimable, uint256 totalCarryForwardBalance)
    {
        StructAccount storage userAccount = _mappingAccounts[_userAddress];
        require(
            userAccount.stakingIds.length > 0,
            "_claimStakingReward(): You have no stakings"
        );

        for (uint256 i; i < userAccount.stakingIds.length; ++i) {
            StructStaking storage stakingAccount = _mappingStakings[
                userAccount.stakingIds[i]
            ];

            require(
                stakingAccount.owner == _userAddress,
                "You are not the owner of this staking."
            );

            if (stakingAccount.isActive) {
                (
                    ,
                    uint256 rewardClaimable,
                    uint256 carryForwardBalance
                ) = _getStakingRewardsById(stakingAccount);

                if (rewardClaimable > 0) {
                    stakingAccount.stakingRewardClaimed += rewardClaimable;
                    totalRewardClaimable += rewardClaimable;
                }

                if (carryForwardBalance > 0) {
                    stakingAccount.initialRewards += carryForwardBalance;
                    totalCarryForwardBalance += carryForwardBalance;
                }
            }
        }

        if (totalRewardClaimable > 0) {
            userAccount.stakingRewardsClaimed += totalRewardClaimable;
            _carryForwardBalance += totalCarryForwardBalance;

            emit ClaimedStakingReward(totalRewardClaimable);
        }
    }

    function claimStakingReward(address _userAddress) external noReentrancy {
        (uint256 rewardClaimable, ) = _claimUserStakingReward(_userAddress);

        require(
            rewardClaimable > 0,
            "_claimUserStakingReward(): No rewards to claim."
        );

        uint256 ethBalanceThis = address(this).balance;

        require(
            ethBalanceThis >= rewardClaimable,
            "claimStakingReward(): Contract has less balance to pay."
        );

        (bool status, ) = payable(_userAddress).call{value: rewardClaimable}(
            ""
        );
        require(status, "claimStakingReward(): Reward ETH Not transfered.");
    }

    function _unStake(address _userAddress)
        private
        returns (uint256 tokenUnStaked, uint256 stakingRewardClaimed)
    {
        StructAccount storage userAccount = _mappingAccounts[_userAddress];

        require(
            userAccount.stakingIds.length > 0,
            "_claimStakingReward(): You have no stakings"
        );

        (uint256 rewardClaimable, ) = _claimUserStakingReward(_userAddress);

        if (rewardClaimable > 0) {
            stakingRewardClaimed += rewardClaimable;
        }

        userAccount.totalValueStaked = 0;
        uint256 calRewards;

        for (uint256 i; i < userAccount.stakingIds.length; ++i) {
            StructStaking storage stakingAccount = _mappingStakings[
                userAccount.stakingIds[i]
            ];

            require(
                stakingAccount.owner == _userAddress,
                "You are not the owner of this staking."
            );

            if (stakingAccount.isActive) {
                stakingAccount.isActive = false;
                tokenUnStaked += stakingAccount.valueStaked;
                calRewards += stakingAccount.stakingRewardClaimed;
                calRewards += stakingAccount.initialRewards;
            }
        }

        require(tokenUnStaked > 0, "_unstake(): No value to unStake.");

        _calStakingReward -= calRewards;

        _valueStaked -= tokenUnStaked;
        emit UnStake(tokenUnStaked);
    }

    function unStake() external {
        address msgSender = msg.sender;
        (uint256 tokenUnStaked, uint256 stakingRewardClaimed) = _unStake(
            msgSender
        );

        if (tokenUnStaked > 0) {
            bool sent = IERC20(_tokenAddress).transfer(
                msgSender,
                _toTokens(_tokenAddress, tokenUnStaked)
            );

            require(sent, "unStake(): Tokens not transfered");
        }

        if (stakingRewardClaimed > 0) {
            (bool status, ) = payable(msgSender).call{
                value: stakingRewardClaimed
            }("");
            require(status, "unstake(): Reward not transfered.");
        }
    }

    function distributeStakingRewards() public payable {
        uint256 msgValue = msg.value;
        require(
            msgValue > 0,
            "distributeStakingRewards(): Reward must be not be zero."
        );
        uint256 currentTime = block.timestamp;

        require(
            msgValue > 0,
            "distributeStakingRewards(): Reward must be greater than zero."
        );

        if (_carryForwardBalance > 0) {
            msgValue += _carryForwardBalance;
            delete _carryForwardBalance;
        }

        _calStakingReward += msgValue;
        _lastTimeRewardDistributed = currentTime;
        _totalStakingRewardsDistributed += msgValue;

        emit DistributeStakingReward(msgValue);
    }

    function getUsersParticipatedList()
        external
        view
        returns (address[] memory)
    {
        return _users;
    }

    function getUserShare(address _userAddress)
        external
        view
        returns (uint256 userShare)
    {
        StructAccount memory userAccount = _mappingAccounts[_userAddress];

        userShare =
            (userAccount.totalValueStaked * 100 * 1 ether) /
            _valueStaked;
    }

    function getContractDefault() external view returns (address tokenAddress) {
        tokenAddress = _tokenAddress;
    }

    function setTokenAddress(address tokenAddress_) external onlyOwner {
        _tokenAddress = tokenAddress_;
    }

    function getContractAnalytics()
        external
        view
        returns (
            uint256 usersCount,
            uint256 stakingsCount,
            uint256 totalStakingRewardsDistributed,
            uint256 calStakingReward,
            uint256 valueStaked,
            uint256 lastTimeRewardDistributed,
            uint256 carryForwardBalance
        )
    {
        usersCount = _users.length;
        stakingsCount = _stakingsCount;
        totalStakingRewardsDistributed = _totalStakingRewardsDistributed;
        calStakingReward = _calStakingReward;
        valueStaked = _valueStaked;
        lastTimeRewardDistributed = _lastTimeRewardDistributed;
        carryForwardBalance = _carryForwardBalance;
    }

    function getUserAccount(address _userAddress)
        external
        view
        returns (StructAccount memory)
    {
        return _mappingAccounts[_userAddress];
    }

    function getStakingById(uint256 _stakingId)
        external
        view
        returns (StructStaking memory)
    {
        return _mappingStakings[_stakingId];
    }

    function _toTokens(address tokenAddress_, uint256 _valueInWei)
        private
        view
        returns (uint256 valueInTokens)
    {
        valueInTokens =
            (_valueInWei * 10**IERC20EXT(tokenAddress_).decimals()) /
            1 ether;
    }

    function _toWei(address _tokenAddress_, uint256 _valueInTokens)
        private
        view
        returns (uint256 valueInWei)
    {
        valueInWei =
            (_valueInTokens * 1 ether) /
            10**IERC20EXT(_tokenAddress_).decimals();
    }
}
