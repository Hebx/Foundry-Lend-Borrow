// SPDX-License-Identifier: MIT
// This contract is not audited!!!
pragma solidity ^0.8.7;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

contract TokenLending is ReentrancyGuard, Ownable {
    /*//////////////////////////////////////////////////////////////
                             ERRORS
    //////////////////////////////////////////////////////////////*/
    error TransferFailed();
    error TokenNotAllowed(address token);
    error NeedsMoreThanZero();
    error InsufficientLiquidity();
    error InsufficientFunds();
    error Low_Health_Factor();
    error RepayedTooMuch();
    error NoDebtToPay();

    /*//////////////////////////////////////////////////////////////
                             STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Maps tokens to their corresponding Chainlink price feed addresses
     */
    mapping(address => address) public s_tokenToPriceFeeds;

    /**
     * @notice List of ERC20 tokens allowed for deposit and borrowing
     */
    address[] public s_allowedTokens;

    /**
     * @notice Nested mapping to track the amount of each token deposited by each account
     * @dev Account -> Token -> Amount
     */
    mapping(address => mapping(address => uint256)) public s_accountToTokenDeposits;

    /**
     * @notice Nested mapping to track the amount of each token borrowed by each account
     * @dev Account -> Token -> Amount
     */
    mapping(address => mapping(address => uint256)) public s_accountToTokenBorrows;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The percentage of the loan value that is given as a reward for liquidating a loan (5%)
     */
    uint256 public constant LIQUIDATION_REWARD = 5;

    /**
     * @notice The loan-to-value ratio at which a loan becomes eligible for liquidation (80%)
     */
    uint256 public constant LIQUIDATION_THRESHOLD = 80;

    /**
     * @notice The minimum health factor required to avoid liquidation (1e18)
     */
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    /*//////////////////////////////////////////////////////////////
                             EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a new token is allowed and its price feed is set
     * @param token The ERC20 token address
     * @param priceFeed The Chainlink price feed address for the token
     */
    event AllowedTokenSet(address token, address priceFeed);

    /**
     * @notice Emitted when a user deposits tokens
     * @param account The address of the user making the deposit
     * @param token The ERC20 token being deposited
     * @param amount The amount of tokens deposited
     */
    event Deposit(address account, address token, uint256 amount);

    /**
     * @notice Emitted when a user borrows tokens
     * @param account The address of the borrower
     * @param token The ERC20 token being borrowed
     * @param amount The amount of tokens borrowed
     */
    event Borrow(address account, address token, uint256 amount);

    /**
     * @notice Emitted when a user withdraws tokens
     * @param account The address of the user making the withdrawal
     * @param token The ERC20 token being withdrawn
     * @param amount The amount of tokens withdrawn
     */
    event Withdraw(address account, address token, uint256 amount);

    /**
     * @notice Emitted when a user repays borrowed tokens
     * @param account The address of the borrower
     * @param token The ERC20 token being repaid
     * @param amount The amount of tokens repaid
     */
    event Repay(address account, address token, uint256 amount);

    /**
     * @notice Emitted when a user's debt position is liquidated
     * @param account The address of the user being liquidated
     * @param repayToken The ERC20 token used to repay the debt
     * @param rewardToken The ERC20 token awarded to the liquidator
     * @param halfDebtInEth The ETH value of half of the user's debt
     * @param liquidator The address of the user performing the liquidation
     */
    event Liquidate(
        address account, address repayToken, address rewardToken, uint256 halfDebtInEth, address liquidator
    );

    /*//////////////////////////////////////////////////////////////
                            Modifiers
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures the token is allowed for deposit and borrowing
     * @param token The address of the token to check
     */
    modifier isAllowedToken(address token) {
        if (s_tokenToPriceFeeds[token] == address(0)) revert TokenNotAllowed(token);
        _;
    }

    /**
     * @notice Ensures the amount specified is greater than zero
     * @param amount The amount to check
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert NeedsMoreThanZero();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits the specified token into the contract
     * @dev Emits a Deposit event on success
     * @param token The address of the ERC20 token to deposit
     * @param amount The amount of the token to deposit
     */
    function deposit(address token, uint256 amount) external nonReentrant isAllowedToken(token) moreThanZero(amount) {
        s_accountToTokenDeposits[msg.sender][token] += amount;
        emit Deposit(msg.sender, token, amount);
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Withdraws the specified token from the contract
     * @dev Emits a Withdraw event on success
     * @param token The address of the ERC20 token to withdraw
     * @param amount The amount of the token to withdraw
     */
    function withdraw(address token, uint256 amount) external nonReentrant moreThanZero(amount) {
        if (s_accountToTokenDeposits[msg.sender][token] < amount) revert InsufficientFunds();
        if (MIN_HEALTH_FACTOR > healthFactor(msg.sender)) revert Low_Health_Factor();
        emit Withdraw(msg.sender, token, amount);
        _pullFunds(msg.sender, token, amount);
    }

    /**
     * @notice Internal function to handle withdrawal logic
     * @param account The account address to withdraw funds from
     * @param token The address of the ERC20 token to withdraw
     * @param amount The amount of the token to withdraw
     */
    function _pullFunds(address account, address token, uint256 amount) private {
        if (s_accountToTokenDeposits[account][token] < amount) revert InsufficientFunds();
        s_accountToTokenDeposits[account][token] -= amount;
        bool success = IERC20(token).transfer(account, amount);
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Borrows the specified token from the contract
     * @dev Emits a Borrow event on success
     * @param token The address of the ERC20 token to borrow
     * @param amount The amount of the token to borrow
     */
    function borrow(address token, uint256 amount) external nonReentrant isAllowedToken(token) moreThanZero(amount) {
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientLiquidity();
        s_accountToTokenBorrows[msg.sender][token] += amount;
        emit Borrow(msg.sender, token, amount);
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Liquidates an account that is below the minimum health factor
     * @dev Emits a Liquidate event on success
     * @param account The account to liquidate
     * @param repayToken The address of the ERC20 token to repay
     * @param rewardToken The address of the ERC20 token to reward the liquidator
     */
    function liquidate(address account, address repayToken, address rewardToken) external nonReentrant {
        if (MIN_HEALTH_FACTOR <= healthFactor(account)) revert Low_Health_Factor();
        uint256 halfDebt = s_accountToTokenBorrows[account][repayToken] / 2;
        if (halfDebt <= 0) revert NoDebtToPay();
        uint256 halfDebtInEth = getEthValue(repayToken, halfDebt);
        if (halfDebtInEth <= 0) revert NoDebtToPay();
        uint256 rewardAmountInEth = (halfDebtInEth * LIQUIDATION_REWARD) / 100;
        uint256 totalRewardAmountInRewardToken = getTokenValueFromEth(rewardToken, rewardAmountInEth + halfDebtInEth);
        emit Liquidate(account, repayToken, rewardToken, halfDebtInEth, msg.sender);

        _repay(account, repayToken, halfDebtInEth);
        _pullFunds(msg.sender, rewardToken, totalRewardAmountInRewardToken);
    }

    /**
     * @notice Repays the specified token for the sender's account
     * @dev Emits a Repay event on success
     * @param token The address of the ERC20 token to repay
     * @param amount The amount of the token to repay
     */
    function repay(address token, uint256 amount) external nonReentrant isAllowedToken(token) moreThanZero(amount) {
        emit Repay(msg.sender, token, amount);
        _repay(msg.sender, token, amount);
    }

    /**
     * @notice Internal function to handle repayment logic
     * @param account The account address to repay funds for
     * @param token The address of the ERC20 token to repay
     * @param amount The amount of the token to repay
     */
    function _repay(address account, address token, uint256 amount) private {
        if (s_accountToTokenBorrows[account][token] < amount) revert RepayedTooMuch();
        s_accountToTokenBorrows[account][token] -= amount;
        bool success = IERC20(token).transferFrom(account, address(this), amount);
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Retrieves the total borrowed and collateral value in ETH for a given user
     * @param user The address of the user to query
     * @return borrowedValueInETH The total value borrowed by the user in ETH
     * @return collateralValueInETH The total collateral value of the user in ETH
     */
    function getAccountInformation(address user)
        public
        view
        returns (uint256 borrowedValueInETH, uint256 collateralValueInETH)
    {
        borrowedValueInETH = getAccountBorrowedValue(user);
        collateralValueInETH = getAccountCollateralValue(user);
    }

    /**
     * @notice Calculates the total collateral value in ETH for a given user
     * @param user The address of the user to query
     * @return The total collateral value in ETH
     */
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInEth = 0;
        for (uint256 i = 0; i < s_allowedTokens.length; i++) {
            address token = s_allowedTokens[i];
            uint256 amount = s_accountToTokenDeposits[user][token];
            uint256 valueInEth = getEthValue(token, amount);
            totalCollateralValueInEth += valueInEth;
        }
        return totalCollateralValueInEth;
    }

    /**
     * @notice Calculates the total borrowed value in ETH for a given user
     * @param user The address of the user to query
     * @return The total borrowed value in ETH
     */
    function getAccountBorrowedValue(address user) public view returns (uint256) {
        uint256 totalBorrowsValueInEth = 0;
        for (uint256 i = 0; i < s_allowedTokens.length; i++) {
            address token = s_allowedTokens[i];
            uint256 amount = s_accountToTokenBorrows[user][token];
            uint256 valueInEth = getEthValue(token, amount);
            totalBorrowsValueInEth += valueInEth;
        }
        return totalBorrowsValueInEth;
    }

    /**
     * @notice Converts the amount of a token to its equivalent value in ETH
     * @param token The address of the token
     * @param amount The amount of the token to convert
     * @return The equivalent value in ETH
     */
    function getEthValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (amount * uint256(price)) / 1e18;
    }

    /**
     * @notice Converts an amount in ETH to its equivalent value in a specified token
     * @param token The address of the token
     * @param amount The amount in ETH to convert
     * @return The equivalent value in the specified token
     */
    function getTokenValueFromEth(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (amount * 1e18) / uint256(price);
    }

    /**
     * @notice Calculates the health factor for a given account
     * @param account The address of the account
     * @return The health factor of the account
     */
    function healthFactor(address account) public view returns (uint256) {
        (uint256 borrowedValueInETH, uint256 collateralValueInETH) = getAccountInformation(account);
        uint256 collateralAdjustedForThreshold = (collateralValueInETH * LIQUIDATION_THRESHOLD) / 100;
        if (borrowedValueInETH == 0) return 100e18;
        return (collateralAdjustedForThreshold * 1e18) / borrowedValueInETH;
    }

    // DAO / OnlyOwner Functions

    /**
     * @notice Sets a token as allowed and associates it with a Chainlink price feed
     * @param token The address of the ERC20 token to allow
     * @param priceFeed The address of the Chainlink price feed for the token
     */
    function setAllowedToken(address token, address priceFeed) external onlyOwner {
        bool foundToken = false;
        uint256 allowedTokensLength = s_allowedTokens.length;
        for (uint256 index = 0; index < allowedTokensLength; index++) {
            if (s_allowedTokens[index] == token) {
                foundToken = true;
                break;
            }
        }
        if (!foundToken) s_allowedTokens.push(token);
        s_tokenToPriceFeeds[token] = priceFeed;
        emit AllowedTokenSet(token, priceFeed);
    }
}
