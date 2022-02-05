//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
	
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

//https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol
//https://docs.uniswap.org/protocol/V2/reference/smart-contracts/router-02
interface IUniswapV2Router02 {
    function WETH () external returns (address);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    //  define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    uint8 public constant wei_decimals = 18;
    uint8 public constant wbtc_decimals = 8;
    uint8 public constant usdt_decimals = 6;
	
	uint64 private constant blockNumber = 1621761058;
	
    address private constant lendingPoolAddress = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9; // Aave v2 market - mainnet
    address private constant uniswapV2FactoryAddress = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address private constant uniswapV2RouterAddress = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
	
    address private constant WBTCAddress = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address private constant USDTAddress = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant WETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
	
    address private constant liqUserAddress = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
	
	ILendingPool lendingPool = ILendingPool(lendingPoolAddress);
	IUniswapV2Router02 router = IUniswapV2Router02(uniswapV2RouterAddress);
	IUniswapV2Factory uV2Factory = IUniswapV2Factory(uniswapV2FactoryAddress);
	IUniswapV2Pair WETHUSDTPair = IUniswapV2Pair (uV2Factory.getPair(WETHAddress, USDTAddress));
	IERC20 WBTC = IERC20(WBTCAddress);
	IERC20 USDT = IERC20(USDTAddress);
	IWETH WETH = IWETH(WETHAddress);

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    receive() external payable {
		
	}
    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        USDT.approve(lendingPoolAddress, 2**256-1);
        WBTC.approve(uniswapV2RouterAddress, 2**256-1);

        // 1. get the target user account data & make sure it is liquidatable
		console.log("1.Querying user health factor after liquidation");
        bool userIsLiquidatable = checkUserLiquidationStatus(liqUserAddress);
		require(userIsLiquidatable);		
		
        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        console.log("2.Making a WETH-USDT pair flashswap with uniswap 2.0");	
		uint256 debtToCoverUSDT = 600000000000;
		WETHUSDTPair.swap(0, debtToCoverUSDT, address(this), " ");
		debtToCoverUSDT = 1145000000000;
		WETHUSDTPair.swap(0, debtToCoverUSDT, address(this), " ");

        // 3. Convert the profit into ETH and send back to sender
		console.log("3.Converting the profit into ETH and sending back to sender");		
        uint256 balanceWBTC = WBTC.balanceOf(address(this));
		uint256 balanceWETH = WETH.balanceOf(address(this));
        console.log("--WETH balance in the contract now: %s.%s(%s)", balanceWETH/(10**wei_decimals), balanceWETH%(10**wei_decimals), balanceWETH); 
		console.log("--WBTC balance in the contract now: %s.%s(%s)", balanceWBTC/(10**wbtc_decimals), balanceWBTC%(10**wbtc_decimals), balanceWBTC); 
		console.log("--Swapping to ETH, sending to caller");
		
		address[] memory path = new address[](2);
        path[0] = WBTCAddress;
        path[1] =  WETHAddress;		
        router.swapExactTokensForETH(balanceWBTC, 0, path, msg.sender, blockNumber);
		
		WETH.withdraw(balanceWETH);
        payable(msg.sender).transfer (balanceWETH);
					
        balanceWBTC = WBTC.balanceOf(address(this));
		balanceWETH = WETH.balanceOf(address(this));
        console.log("--WETH balance in the contract now: %s.%s(%s)", balanceWETH/(10**wei_decimals), balanceWETH%(10**wei_decimals), balanceWETH); 
		console.log("--WBTC balance in the contract now: %s.%s(%s)", balanceWBTC/(10**wbtc_decimals), balanceWBTC%(10**wbtc_decimals), balanceWBTC);       
        
		console.log("4.Querying user health factor after liquidation");
		userIsLiquidatable = checkUserLiquidationStatus(liqUserAddress);
		require(!userIsLiquidatable);
        // END TODO
    }
	
	function checkUserLiquidationStatus(address userAddress) internal view returns (bool userIsLiquidatable ) {
		uint256 totalCollateralETH;
		uint256 totalDebtETH;
		uint256 availableBorrowsETH;
		uint256 currentLiquidationThreshold;
		uint256 ltv;
		uint256 healthFactor;
		
		(
            totalCollateralETH,
            totalDebtETH,
            availableBorrowsETH,
            currentLiquidationThreshold,
            ltv,
            healthFactor
        ) = lendingPool.getUserAccountData(userAddress);
		
		bool userLiquidatable = healthFactor < 10**health_factor_decimals;
		(uint112 reserve0, uint112 reserve1, ) = WETHUSDTPair.getReserves();
		uint256 totalDebtUSDT = getAmountOut(totalDebtETH, reserve0, reserve1);
		uint256 totalCollateralUSDT = getAmountOut(totalCollateralETH, reserve0, reserve1);
		
		console.log("--Health factor: %s.%s(%s)", 
			 healthFactor / (10**health_factor_decimals), healthFactor % (10**health_factor_decimals), healthFactor);
		console.log("--User is liquidatable: %s", userLiquidatable);
		console.log("--Total ETH debt %s.%s(%s)", 
			totalDebtETH / (10**wei_decimals), totalDebtETH % (10**wei_decimals), totalDebtETH);
		console.log("--Total ETH collateral %s.%s(%s)", 
			totalCollateralETH / (10**wei_decimals), totalCollateralETH % (10**wei_decimals), totalCollateralETH);		
		console.log("--Usdt debt: %s.%s(%s)", 
			totalDebtUSDT / (10**usdt_decimals), totalDebtUSDT % (10**usdt_decimals), totalDebtUSDT);	
		console.log("--Usdt collateral: %s.%s(%s)", 
			totalCollateralUSDT / (10**usdt_decimals), totalCollateralUSDT % (10**usdt_decimals), totalCollateralUSDT);
			 
		return userLiquidatable;
	}
	

    // required by the swap
    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
		address token0 = IUniswapV2Pair(msg.sender).token0();  
		address token1 = IUniswapV2Pair(msg.sender).token1();
		address senderPair = uV2Factory.getPair(token0, token1);
		console.log("--Sender address %s, uniswap pair address %s", msg.sender, senderPair);
		assert(msg.sender == senderPair); // ensure that msg.sender is a V2 pair
		
		(uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(msg.sender).getReserves();

        // 2.1 liquidate the target user		
        lendingPool.liquidationCall(WBTCAddress, USDTAddress, liqUserAddress, amount1, false);
		
        // 2.2 swap WBTC for other things or repay directly				
		uint256 amountIn = getAmountIn (amount1, reserve0, reserve1);
        address[] memory path = new address[](2);
        path[0] = WBTCAddress;
        path[1] = WETHAddress;		
		console.log("--FlahsSwap reserve ETH: %s.%s(%s),", reserve0 / (10**wei_decimals), reserve0 % (10**wei_decimals), reserve0);
		console.log("--FlahsSwap reserve USDT: %s.%s(%s)", reserve1 / (10**usdt_decimals), reserve1 % (10**usdt_decimals), reserve1);
		console.log("--FlahsSwap In amount ETH: %s.%s(%s)", amountIn / (10**wei_decimals), amountIn % (10**wei_decimals), amountIn);
        router.swapTokensForExactTokens(amountIn, 2**256-1, path, msg.sender, blockNumber);

        // 2.3 repay
        //    *** Your code here ***
        
        // END TODO
    }
}
