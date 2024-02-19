// SPDX-LICENSE-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {TokenLending} from "../../src/TokenLending.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {DeployTokenLending} from "../../script/DeployTokenLending.s.sol";

contract TestTokenLending is Test {
    DeployTokenLending public deployTokenLending;
    TokenLending public tokenLending;
    HelperConfig public config;
    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 20 ether;

    function setUp() external {
        // Directly deploy the TokenLending contract to ensure this test contract is the owner
        tokenLending = new TokenLending();

        // Assuming the HelperConfig setup is needed for other configurations
        config = new HelperConfig();

        // Fetch addresses from HelperConfig
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        // Now this contract should already be the owner and can set allowed tokens
        tokenLending.setAllowedToken(weth, ethUsdPriceFeed);
        tokenLending.setAllowedToken(wbtc, btcUsdPriceFeed);

        // Mint tokens and set up the environment for testing
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    modifier depositedWethCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(tokenLending), AMOUNT_COLLATERAL);
        tokenLending.deposit(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedWbtcCollateral() {
        vm.startPrank(USER);
        ERC20Mock(wbtc).approve(address(tokenLending), AMOUNT_COLLATERAL);
        tokenLending.deposit(wbtc, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDeposit() public depositedWethCollateral {
        // Verify the deposit was successful
        uint256 depositedAmount = tokenLending.s_accountToTokenDeposits(USER, weth);
        assertEq(depositedAmount, AMOUNT_COLLATERAL, "Deposit amount does not match");
    }

    function testWithdraw() public depositedWethCollateral {
        // USER withdraws a portion of the WETH
        uint256 withdrawAmount = AMOUNT_COLLATERAL / 2;
        vm.prank(USER);
        tokenLending.withdraw(weth, withdrawAmount);

        // Verify the withdrawal was successful
        uint256 remainingDeposit = tokenLending.s_accountToTokenDeposits(USER, weth);
        assertEq(remainingDeposit, AMOUNT_COLLATERAL - withdrawAmount, "Withdrawal amount does not match");
    }

    function testBorrow() public depositedWethCollateral depositedWbtcCollateral {
        // USER borrows WBTC against their WETH collateral
        uint256 borrowAmount = 1 ether;
        vm.prank(USER);
        tokenLending.borrow(wbtc, borrowAmount);

        // Verify the borrow was successful
        uint256 borrowedAmount = tokenLending.s_accountToTokenBorrows(USER, wbtc);
        assertEq(borrowedAmount, borrowAmount, "Borrowed amount does not match");
    }

    function testRepay() public depositedWethCollateral depositedWbtcCollateral {
        // Setup: USER borrows WBTC
        uint256 borrowAmount = 1 ether;
        uint256 repayAmount = 1 ether;
        vm.startPrank(USER);
        ERC20Mock(wbtc).approve(address(tokenLending), AMOUNT_COLLATERAL);

        tokenLending.borrow(wbtc, borrowAmount);

        // USER repays the WBTC loan
        tokenLending.repay(wbtc, repayAmount);
        vm.stopPrank();

        // Verify the repay was successful
        uint256 remainingBorrow = tokenLending.s_accountToTokenBorrows(USER, wbtc);
        assertEq(remainingBorrow, 0, "Loan not fully repaid");
    }
}
