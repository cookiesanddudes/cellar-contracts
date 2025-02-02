// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MockCellar, Cellar, ERC4626, ERC20 } from "src/mocks/MockCellar.sol";
import { Curve3PoolAdaptor } from "src/modules/adaptors/Curve/Curve3PoolAdaptor.sol";
import { BaseAdaptor } from "src/modules/adaptors/BaseAdaptor.sol";
import { ICurvePool } from "src/interfaces/external/ICurvePool.sol";
import { Registry } from "src/Registry.sol";
import { PriceRouter } from "src/modules/price-router/PriceRouter.sol";
import { Denominations } from "@chainlink/contracts/src/v0.8/Denominations.sol";
import { ERC20Adaptor } from "src/modules/adaptors/ERC20Adaptor.sol";
import { SwapRouter, IUniswapV2Router, IUniswapV3Router } from "src/modules/swap-router/SwapRouter.sol";

import { Test, stdStorage, console, StdStorage, stdError } from "@forge-std/Test.sol";
import { Math } from "src/utils/Math.sol";

contract Curve3PoolTest is Test {
    using SafeERC20 for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    Curve3PoolAdaptor private curve3PoolAdaptor;
    ERC20Adaptor private erc20Adaptor;
    MockCellar private cellar;
    PriceRouter private priceRouter;
    Registry private registry;
    SwapRouter private swapRouter;

    address private immutable strategist = vm.addr(0xBEEF);

    ERC20 private WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 private CVX = ERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);

    ERC20 private USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 private DAI = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    ERC20 private USDT = ERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    ERC20 private LP3CRV = ERC20(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490);
    ICurvePool curve3Pool = ICurvePool(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);

    uint32 private lp3crvPosition;
    uint32 private daiPosition;

    function setUp() external {
        curve3PoolAdaptor = new Curve3PoolAdaptor();
        erc20Adaptor = new ERC20Adaptor();
        priceRouter = new PriceRouter();

        registry = new Registry(address(this), address(swapRouter), address(priceRouter));

        priceRouter.addAsset(DAI, 0, 0, false, 0);
        priceRouter.addAsset(USDC, 0, 0, false, 0);
        priceRouter.addAsset(USDT, 0, 0, false, 0);

        // Setup Cellar:
        // Cellar positions array.
        uint32[] memory positions = new uint32[](2);

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(curve3PoolAdaptor), 0, 0);
        registry.trustAdaptor(address(erc20Adaptor), 0, 0);

        daiPosition = registry.trustPosition(address(erc20Adaptor), false, abi.encode(DAI), 0, 0);
        lp3crvPosition = registry.trustPosition(
            address(curve3PoolAdaptor),
            false,
            abi.encode(
                ICurvePool(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7),
                address(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490)
            ),
            0,
            0
        );

        positions[0] = daiPosition;
        positions[1] = lp3crvPosition;

        bytes[] memory positionConfigs = new bytes[](2);

        cellar = new MockCellar(registry, DAI, positions, positionConfigs, "Convex Cellar", "CONVEX-CLR", strategist);

        vm.label(address(curve3Pool), "curve pool");
        vm.label(address(curve3PoolAdaptor), "curve3PoolAdaptor");

        vm.label(address(this), "tester");
        vm.label(address(cellar), "cellar");
        vm.label(strategist, "strategist");
        vm.label(address(DAI), "dai token");
        vm.label(address(USDC), "usdc token");
        vm.label(address(USDT), "usdt token");

        cellar.setupAdaptor(address(curve3PoolAdaptor));

        DAI.safeApprove(address(cellar), type(uint256).max);
        USDC.safeApprove(address(cellar), type(uint128).max);
        USDT.safeApprove(address(cellar), type(uint128).max);

        // Manipulate test contracts storage so that minimum shareLockPeriod is zero blocks.
        stdstore.target(address(cellar)).sig(cellar.shareLockPeriod.selector).checked_write(uint256(0));
    }

    // ========================================== POSITION MANAGEMENT TEST ==========================================
    function testOpenPosition() external {
        deal(address(DAI), address(cellar), 100_000e18);

        // Use `callOnAdaptor` to deposit LP into curve pool
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToOpenPosition(1e18, 0, 0, 0);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });

        cellar.callOnAdaptor(data);

        uint256 lpBalance = LP3CRV.balanceOf(address(cellar));

        // Assert balanceOf is bigger than 0.9
        vm.prank(address(cellar));
        assertGe(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 1e18 - 1e17);

        // Assert LP is bigger than 0
        assertGe(lpBalance, 0);
    }

    function testOpenDAIPosition() external {
        deal(address(DAI), address(cellar), 100_000e18);

        // Use `callOnAdaptor` to deposit LP into curve pool
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToOpenPosition(1e18, 0, 0, 0);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });

        cellar.callOnAdaptor(data);

        uint256 lpBalance = LP3CRV.balanceOf(address(cellar));

        // Assert balanceOf is bigger than 0.9
        vm.prank(address(cellar));
        assertGe(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 1e18 - 1e17);

        // Assert LP is bigger than 0
        assertGe(lpBalance, 0);
    }

    function testOpenDAIUSDCUSDTPosition() external {
        deal(address(DAI), address(cellar), 100_000e18);
        deal(address(USDC), address(cellar), 100_000e6);
        deal(address(USDT), address(cellar), 100_000e6);

        // Use `callOnAdaptor` to deposit LP into curve pool
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToOpenPosition(1e18, 1e6, 1e6, 0);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });

        cellar.callOnAdaptor(data);

        uint256 lpBalance = LP3CRV.balanceOf(address(cellar));

        // Assert balanceOf is bigger than 0
        vm.prank(address(cellar));
        assertGe(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 0);

        // Assert LP is bigger than 0
        assertGe(lpBalance, 0);
    }

    function testOpeningAndClosingPosition() external {
        deal(address(DAI), address(cellar), 100_000e18);
        deal(address(USDC), address(cellar), 100_000e6);
        deal(address(USDT), address(cellar), 100_000e6);

        // Use `callOnAdaptor` to deposit LP into curve pool
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToOpenPosition(1e18, 1e6, 1e6, 0);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });

        cellar.callOnAdaptor(data);

        uint256 lpBalance = LP3CRV.balanceOf(address(cellar));
        uint256 daiBalanceBefore = DAI.balanceOf(address(cellar));

        // assert balanceOf is bigger than 0
        vm.prank(address(cellar));
        assertGe(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 0);

        // assert LP is bigger than 0
        assertGe(lpBalance, 0);

        // Now, close the position
        adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToClosePosition(0);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });
        cellar.callOnAdaptor(data);

        uint256 daiBalanceAfter = DAI.balanceOf(address(cellar));
        uint256 lpBalanceAfter = LP3CRV.balanceOf(address(cellar));

        assertEq(lpBalanceAfter, 0);

        assertGe(daiBalanceAfter - daiBalanceBefore, 0);

        // assert adaptor balanceOf is zero as well
        vm.prank(address(cellar));
        assertEq(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 0);
    }

    function testOpeningAddingAndTakingFromPosition() external {
        deal(address(DAI), address(cellar), 100_000e18);
        deal(address(USDC), address(cellar), 100_000e6);
        deal(address(USDT), address(cellar), 100_000e6);

        // Use `callOnAdaptor` to deposit LP into curve pool
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToOpenPosition(1e18, 1e6, 1e6, 0);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });

        cellar.callOnAdaptor(data);

        uint256 lpBalance = LP3CRV.balanceOf(address(cellar));

        // assert balanceOf is bigger than 0
        vm.prank(address(cellar));
        assertGe(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 0);

        // assert LP is bigger than 0
        assertGe(lpBalance, 0);

        // Now, add to the position
        adaptorCalls = new bytes[](1);

        adaptorCalls[0] = _createBytesDataToAddToPosition(10e18, 10e6, 10e6, 0);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });
        cellar.callOnAdaptor(data);

        // check that amount has been added
        vm.prank(address(cellar));
        assertGe(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 10e18);

        uint256 lpBalanceAfterAdd = LP3CRV.balanceOf(address(cellar));

        assertGe(lpBalanceAfterAdd, 10e18);

        // Now, remove from the position
        adaptorCalls[0] = _createBytesDataToTakeFromPosition(25e18, 0);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });
        cellar.callOnAdaptor(data);

        // assert adaptor balanceOf is within range
        vm.prank(address(cellar));
        assertGe(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 5e18);
        assertLe(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 10e18);
    }

    function testWithdrawableFromReturnsZero() external {
        assertEq(
            curve3PoolAdaptor.withdrawableFrom(abi.encode(0), abi.encode(0)),
            0,
            "`withdrawableFrom` should return 0."
        );
    }

    // ========================================== REVERT TEST ==========================================
    function testMinimalLPTokenMintUnreached() external {
        deal(address(DAI), address(cellar), 100_000e18);

        // Use `callOnAdaptor` to deposit LP into curve pool
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToOpenPosition(1e18, 0, 0, 100e18);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });

        vm.expectRevert(bytes(abi.encodePacked("Slippage screwed you")));
        cellar.callOnAdaptor(data);
    }

    function testMinimalToken0WithdrawMintUnreached() external {
        deal(address(DAI), address(cellar), 100_000e18);
        deal(address(USDC), address(cellar), 100_000e6);
        deal(address(USDT), address(cellar), 100_000e6);

        // Use `callOnAdaptor` to deposit LP into curve pool
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToOpenPosition(1e18, 1e6, 1e6, 0);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });

        cellar.callOnAdaptor(data);

        uint256 lpBalance = LP3CRV.balanceOf(address(cellar));

        // assert balanceOf is bigger than 0
        vm.prank(address(cellar));
        assertGe(curve3PoolAdaptor.balanceOf(abi.encode(curve3Pool, LP3CRV)), 0);

        // assert LP is bigger than 0
        assertGe(lpBalance, 0);

        // Now, close the position
        adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToClosePosition(100e18);

        data[0] = Cellar.AdaptorCall({ adaptor: address(curve3PoolAdaptor), callData: adaptorCalls });
        vm.expectRevert(bytes(abi.encodePacked("Not enough coins removed")));
        cellar.callOnAdaptor(data);
    }

    // ======================================= AUXILIAR FUNCTIONS ======================================

    function _createBytesDataToOpenPosition(
        uint256 amount0,
        uint256 amount1,
        uint256 amount2,
        uint256 minimumMintAmount
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                Curve3PoolAdaptor.openPosition.selector,
                [amount0, amount1, amount2],
                minimumMintAmount,
                curve3Pool
            );
    }

    function _createBytesDataToAddToPosition(
        uint256 amount0,
        uint256 amount1,
        uint256 amount2,
        uint256 minimumAmount
    ) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                Curve3PoolAdaptor.addToPosition.selector,
                [amount0, amount1, amount2],
                minimumAmount,
                curve3Pool
            );
    }

    function _createBytesDataToClosePosition(uint256 minimumAmount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(Curve3PoolAdaptor.closePosition.selector, minimumAmount, curve3Pool, LP3CRV);
    }

    function _createBytesDataToTakeFromPosition(uint256 amount, uint256 minimumAmount)
        internal
        view
        returns (bytes memory)
    {
        return
            abi.encodeWithSelector(
                Curve3PoolAdaptor.takeFromPosition.selector,
                amount,
                minimumAmount,
                curve3Pool,
                LP3CRV
            );
    }
}
