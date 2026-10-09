// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {LaunchCore} from "../src/LaunchCore.sol";
import {MockUsdc} from "../src/MockUsdc.sol";
import {ILaunchCore, PERCENT_POINT, PRICE_POINT} from "../src/interfaces/ILaunchCore.sol";

/// 发币、mock 买卖和报价币手续费分成。
/// 合约通过 ERC1967 代理部署，和正式脚本一致。报价币是 6 位小数的 MockUsdc，项目代币是 18 位。
/// 无子 pad 费率 0.1%，平台和发币人各一半；有子 pad 费率 0.15%，40% / 40% / 20%。
/// 平台费进合约本身，发币人费进 owner，子 pad 费进单独地址。分成比例用事件核对。
contract LaunchCoreFlowTest is Test {
    uint256 private constant FEE_RATE_NO_SUBPAD = 10;
    uint256 private constant FEE_RATE_WITH_SUBPAD = 15;
    uint256 private constant INIT_PRICE = 1 ether;
    uint256 private constant TOTAL_SUPPLY = 1_000_000 ether;

    LaunchCore internal core;
    MockUsdc internal usdc;

    address internal owner = makeAddr("owner");
    address internal trader = makeAddr("trader");
    address internal subpadFeeTo = makeAddr("subpad");

    /// 部署报价币、实现合约和代理。给交易者铸入足够的报价币，用来支付买入和卖出手续费。
    function setUp() public {
        usdc = new MockUsdc();
        LaunchCore implementation = new LaunchCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(LaunchCore.initialize, (owner)));
        core = LaunchCore(address(proxy));
        usdc.mint(trader, 1_000_000_000 ether);
    }

    /// 无子 pad 发币：总量在代理合约里，池子费率为 0.1%，卖出量从 0 开始。
    function test_createToken_withoutSubpad() public {
        vm.recordLogs();
        (bytes32 poolId, address token) = _createToken("NoPad", "NPAD", 0, address(0));
        _assertTokenCreated(poolId, token, "NoPad", "NPAD", TOTAL_SUPPLY);

        assertEq(IERC20Metadata(token).name(), "NoPad");
        assertEq(IERC20Metadata(token).symbol(), "NPAD");
        assertEq(IERC20Metadata(token).decimals(), 18);
        assertEq(IERC20(token).totalSupply(), TOTAL_SUPPLY);
        assertEq(IERC20(token).balanceOf(address(core)), TOTAL_SUPPLY);

        _assertPool(poolId, token, 0, address(0), FEE_RATE_NO_SUBPAD, 0);
    }

    /// 有子 pad 发币：费率 0.15%，子 pad id 和收款地址写入池子。
    function test_createToken_withSubpad() public {
        (bytes32 poolId, address token) = _createToken("WithPad", "WPAD", 7, subpadFeeTo);

        _assertPool(poolId, token, 7, subpadFeeTo, FEE_RATE_WITH_SUBPAD, 0);
    }

    /// 非 owner 不能发币。
    function test_createToken_revertsIfNotOwner() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, trader));
        core.createToken(_params("Nope", "NO", 0, address(0)));
    }

    /// 暂停后不能发币、不能成交。恢复后可以继续买。没有 PAUSER_ROLE 不能暂停。
    function test_pause_blocksCreateAndSwap() public {
        (bytes32 poolId, address token) = _createToken("Pause", "PAUSE", 0, address(0));
        _approveTrader(token);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, trader, core.PAUSER_ROLE())
        );
        vm.prank(trader);
        core.pause();

        vm.prank(owner);
        core.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(owner);
        core.createToken(_params("Later", "LATE", 0, address(0)));

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _swap(poolId, 1 ether, 0);

        vm.prank(owner);
        core.unpause();
        _swap(poolId, 1 ether, 0);
        assertEq(IERC20(token).balanceOf(trader), 1 ether);
    }

    /// 无子 pad：费率 0.1%，平台和创建者各 50%。先按代币数量买入，再卖出一部分。
    function test_flow_buyThenSell_feeWithoutSubpad() public {
        (bytes32 poolId, address token) = _createToken("Flow", "FLOW", 0, address(0));
        _approveTrader(token);

        uint256 buyTokens = 1_000 ether;
        uint256 buyQuote = _quoteForTokens(buyTokens, INIT_PRICE);
        uint256 buyFee = _fee(buyQuote, FEE_RATE_NO_SUBPAD);
        uint256 buyNet = buyQuote - buyFee;

        assertEq(buyQuote, 1_000 ether);
        assertEq(buyFee, 1 ether);
        assertEq(buyNet, 999 ether);

        uint256 traderQuoteBefore = usdc.balanceOf(trader);
        vm.recordLogs();
        _swap(poolId, int256(buyTokens), 0);

        assertEq(IERC20(token).balanceOf(trader), buyTokens);
        assertEq(IERC20(token).balanceOf(address(core)), TOTAL_SUPPLY - buyTokens);
        assertEq(usdc.balanceOf(trader), traderQuoteBefore - buyQuote);
        assertEq(usdc.balanceOf(address(core)), buyNet + buyFee / 2);
        assertEq(usdc.balanceOf(owner), buyFee / 2);
        _expectTrade(poolId, _fill(token, true, buyTokens, buyQuote, buyNet, INIT_PRICE, buyFee / 2, buyFee / 2, 0));

        uint256 sellSumAfterBuy = buyTokens;
        uint256 priceAfterBuy = _curvePrice(INIT_PRICE, sellSumAfterBuy);
        assertEq(priceAfterBuy, 11 ether);
        _assertPool(poolId, token, 0, address(0), FEE_RATE_NO_SUBPAD, sellSumAfterBuy);

        uint256 sellTokens = 80 ether;
        uint256 sellQuote = _quoteForTokens(sellTokens, priceAfterBuy);
        uint256 sellFee = _fee(sellQuote, FEE_RATE_NO_SUBPAD);
        uint256 sellNet = sellQuote - sellFee;

        assertEq(sellQuote, 880 ether);
        assertEq(sellFee, 0.88 ether);
        assertEq(sellNet, 879.12 ether);

        // 卖出时手续费从交易者持有的报价币划走，合约再支付扣费后的报价币。
        vm.recordLogs();
        _swap(poolId, -int256(sellTokens), 0);

        assertEq(IERC20(token).balanceOf(trader), buyTokens - sellTokens);
        assertEq(usdc.balanceOf(trader), traderQuoteBefore - buyQuote - sellFee + sellNet);
        assertEq(usdc.balanceOf(address(core)), buyNet + buyFee / 2 - sellNet + sellFee / 2);
        assertEq(usdc.balanceOf(owner), buyFee / 2 + sellFee / 2);
        _expectTrade(
            poolId, _fill(token, false, sellTokens, sellQuote, sellNet, priceAfterBuy, sellFee / 2, sellFee / 2, 0)
        );
        _assertPool(poolId, token, 0, address(0), FEE_RATE_NO_SUBPAD, sellSumAfterBuy - sellTokens);
    }

    /// 有子 pad：费率 0.15%，平台 40%、创建者 40%、子 pad 20%。按报价币数量买卖。
    function test_flow_buyThenSell_feeWithSubpad() public {
        (bytes32 poolId, address token) = _createToken("Sub", "SUB", 9, subpadFeeTo);
        _approveTrader(token);

        uint256 buyQuote = 1_000 ether;
        uint256 buyFee = _fee(buyQuote, FEE_RATE_WITH_SUBPAD);
        uint256 buyNet = buyQuote - buyFee;
        uint256 buyTokens = _tokensForQuote(buyNet, INIT_PRICE);

        assertEq(buyFee, 1.5 ether);
        assertEq(buyNet, 998.5 ether);
        assertEq(buyTokens, 998.5 ether);

        uint256 traderQuoteBefore = usdc.balanceOf(trader);
        vm.recordLogs();
        _swap(poolId, 0, int256(buyQuote));

        assertEq(IERC20(token).balanceOf(trader), buyTokens);
        assertEq(usdc.balanceOf(trader), traderQuoteBefore - buyQuote);
        assertEq(usdc.balanceOf(address(core)), buyNet + _share(buyFee, 40));
        assertEq(usdc.balanceOf(owner), _share(buyFee, 40));
        assertEq(usdc.balanceOf(subpadFeeTo), buyFee - _share(buyFee, 40) - _share(buyFee, 40));
        _expectTrade(
            poolId,
            _fill(
                token, true, buyTokens, buyQuote, buyNet, INIT_PRICE, _share(buyFee, 40), _share(buyFee, 40), 0.3 ether
            )
        );

        _sellQuoteWithSubpad(poolId, token, buyTokens);
    }

    /// 买入之后按报价币总额卖出一小段。单独成函数，避免主测试里局部变量把编译栈撑满。
    /// 卖出数量要小于池子里的报价币，因为曲线价格已经抬高，池子只持有买入时扣费后的报价币。
    function _sellQuoteWithSubpad(bytes32 poolId, address token, uint256 buyTokens) internal {
        uint256 priceAfterBuy = _curvePrice(INIT_PRICE, buyTokens);
        uint256 sellQuote = 100 ether;
        uint256 sellFee = _fee(sellQuote, FEE_RATE_WITH_SUBPAD);
        uint256 sellNet = sellQuote - sellFee;
        uint256 sellTokens = _tokensForQuote(sellNet, priceAfterBuy);
        _swapAndCheckSellBalances(poolId, token, buyTokens, sellTokens, sellQuote, sellFee, sellNet);
        _assertPool(poolId, token, 9, subpadFeeTo, FEE_RATE_WITH_SUBPAD, buyTokens - sellTokens);
        _expectSellFill(poolId, token, sellTokens, sellQuote, sellNet, priceAfterBuy, _share(sellFee, 40), sellFee);
    }

    function _swapAndCheckSellBalances(
        bytes32 poolId,
        address token,
        uint256 buyTokens,
        uint256 sellTokens,
        uint256 sellQuote,
        uint256 sellFee,
        uint256 sellNet
    ) internal {
        uint256 traderQuoteBefore = usdc.balanceOf(trader);
        uint256 coreQuoteBefore = usdc.balanceOf(address(core));
        uint256 ownerQuoteBefore = usdc.balanceOf(owner);
        uint256 subpadQuoteBefore = usdc.balanceOf(subpadFeeTo);
        uint256 platformPart = _share(sellFee, 40);

        vm.recordLogs();
        _swap(poolId, 0, -int256(sellQuote));

        assertEq(IERC20(token).balanceOf(trader), buyTokens - sellTokens);
        assertEq(usdc.balanceOf(trader), traderQuoteBefore - sellFee + sellNet);
        assertEq(usdc.balanceOf(address(core)), coreQuoteBefore - sellNet + platformPart);
        assertEq(usdc.balanceOf(owner), ownerQuoteBefore + platformPart);
        assertEq(usdc.balanceOf(subpadFeeTo), subpadQuoteBefore + sellFee - platformPart * 2);
    }

    function _expectSellFill(
        bytes32 poolId,
        address token,
        uint256 sellTokens,
        uint256 sellQuote,
        uint256 sellNet,
        uint256 price,
        uint256 platformPart,
        uint256 sellFee
    ) internal view {
        ExpectedFill memory fill;
        fill.token = token;
        fill.isBuy = false;
        fill.tokenAmount = sellTokens;
        fill.quoteAmount = sellQuote;
        fill.quoteNet = sellNet;
        fill.price = price;
        fill.platformFee = platformPart;
        fill.creatorFee = platformPart;
        fill.subpadFee = sellFee - platformPart * 2;
        _expectTrade(poolId, fill);
    }

    /// 手续费为 3 时，40% 向下取整各得 1，最后的子 pad 拿走余下的 1。
    function test_feeSplit_lastRuleTakesRemainder() public {
        (bytes32 poolId, address token) = _createToken("Dust", "DUST", 1, subpadFeeTo);
        _approveTrader(token);

        // 报价 2000，费率 0.15% => 手续费 3。40% 各得 1，子 pad 拿走余下的 1。
        vm.recordLogs();
        _swap(poolId, 2000, 0);

        _expectTrade(poolId, _fill(token, true, 2000, 2000, 1997, INIT_PRICE, 1, 1, 1));
        assertEq(usdc.balanceOf(owner), 1);
        assertEq(usdc.balanceOf(subpadFeeTo), 1);
        assertEq(usdc.balanceOf(address(core)), 1998);
        assertEq(IERC20(token).balanceOf(trader), 2000);
    }

    /// 池子未创建时 token 地址是 0。
    function test_mockSwap_revertsWhenPoolMissing() public {
        vm.expectRevert(bytes("Pool not found"));
        core.mockSwap(ILaunchCore.SwapParams({poolId: bytes32(uint256(1)), tokenAmount: 1, quoteTokenAmount: 0}));
    }

    /// 起始价为 0 且还没人买过时，曲线价格是 0，拒绝成交。
    function test_mockSwap_revertsWhenPriceZero() public {
        (bytes32 poolId, address token) = _createTokenAtPrice("Zero", "ZERO", 0);
        _approveTrader(token);

        vm.expectRevert(bytes("price"));
        _swap(poolId, 1 ether, 0);
    }

    /// 代币数量和报价币数量都是 0，没有成交额。
    function test_mockSwap_revertsWhenAmountEmpty() public {
        (bytes32 poolId, address token) = _createToken("Empty", "EMP", 0, address(0));
        _approveTrader(token);

        vm.expectRevert(bytes("empty swap"));
        _swap(poolId, 0, 0);
    }

    /// 卖出量不能超过当前净卖出。买入 100 枚后再卖 101 枚会回退，手续费转账一并撤销。
    function test_mockSwap_revertsWhenSellExceedsSold() public {
        (bytes32 poolId, address token) = _createToken("Over", "OVER", 0, address(0));
        _approveTrader(token);
        _swap(poolId, 100 ether, 0);

        vm.expectRevert(bytes("sellSum"));
        _swap(poolId, -101 ether, 0);
    }

    /// 核对 TokenCreated。报价币符号来自 MockUsdc，tickSpacing 固定为 0。
    function _assertTokenCreated(
        bytes32 poolId,
        address token,
        string memory name,
        string memory symbol,
        uint256 launchSupply
    ) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("TokenCreated(bytes32,address,address,string,string,address,string,uint256,int24)");
        uint256 matches;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 4 || logs[i].topics[0] != topic) continue;
            assertEq(logs[i].topics[1], poolId);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), owner);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), token);
            _checkTokenCreatedData(logs[i].data, name, symbol, launchSupply);
            matches++;
        }
        assertEq(matches, 1);
    }

    function _checkTokenCreatedData(bytes memory data, string memory name, string memory symbol, uint256 launchSupply)
        internal
        view
    {
        (
            string memory tokenName,
            string memory tokenSymbol,
            address quoteToken,
            string memory quoteSymbol,
            uint256 supply,
            int24 tickSpacing
        ) = abi.decode(data, (string, string, address, string, uint256, int24));
        assertEq(tokenName, name);
        assertEq(tokenSymbol, symbol);
        assertEq(quoteToken, address(usdc));
        assertEq(quoteSymbol, "MockUSDC");
        assertEq(supply, launchSupply);
        assertEq(tickSpacing, 0);
    }

    /// 用代理当前 nonce 预测即将创建的代币地址，发币后再用创建者、代币、报价币算出 poolId。
    function _createToken(string memory name, string memory symbol, uint256 subpadId, address feeTo)
        internal
        returns (bytes32 poolId, address token)
    {
        token = vm.computeCreateAddress(address(core), vm.getNonce(address(core)));
        vm.prank(owner);
        core.createToken(_params(name, symbol, subpadId, feeTo));
        poolId = keccak256(abi.encode(owner, token, address(usdc)));
    }

    function _createTokenAtPrice(string memory name, string memory symbol, uint256 initPrice)
        internal
        returns (bytes32 poolId, address token)
    {
        ILaunchCore.CreateTokenParams memory params = _params(name, symbol, 0, address(0));
        params.initPrice = initPrice;
        token = vm.computeCreateAddress(address(core), vm.getNonce(address(core)));
        vm.prank(owner);
        core.createToken(params);
        poolId = keccak256(abi.encode(owner, token, address(usdc)));
    }

    function _params(string memory name, string memory symbol, uint256 subpadId, address feeTo)
        internal
        view
        returns (ILaunchCore.CreateTokenParams memory)
    {
        return ILaunchCore.CreateTokenParams({
            useMockSwap: true,
            tokenName: name,
            tokenSymbol: symbol,
            tokenDecimals: 18,
            totalSupply: TOTAL_SUPPLY,
            quoteToken: address(usdc),
            initPrice: INIT_PRICE,
            subpadId: subpadId,
            subpadFeeTo: feeTo
        });
    }

    function _approveTrader(address token) internal {
        vm.startPrank(trader);
        usdc.approve(address(core), type(uint256).max);
        IERC20(token).approve(address(core), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bytes32 poolId, int256 tokenAmount, int256 quoteTokenAmount) internal {
        vm.prank(trader);
        core.mockSwap(
            ILaunchCore.SwapParams({poolId: poolId, tokenAmount: tokenAmount, quoteTokenAmount: quoteTokenAmount})
        );
    }

    struct PoolView {
        bool useMockSwap;
        bytes32 poolId;
        address creator;
        address token;
        address quoteToken;
        uint256 initPrice;
        uint256 sellSum;
        uint256 subpadId;
        address subpadFeeTo;
        uint256 feeRate;
    }

    function _assertPool(
        bytes32 poolId,
        address token,
        uint256 subpadId,
        address feeTo,
        uint256 feeRate,
        uint256 sellSum
    ) internal view {
        PoolView memory pool = _pool(poolId);
        assertTrue(pool.useMockSwap);
        assertEq(pool.poolId, poolId);
        assertEq(pool.creator, owner);
        assertEq(pool.token, token);
        assertEq(pool.quoteToken, address(usdc));
        assertEq(pool.initPrice, INIT_PRICE);
        assertEq(pool.sellSum, sellSum);
        assertEq(pool.subpadId, subpadId);
        assertEq(pool.subpadFeeTo, feeTo);
        assertEq(pool.feeRate, feeRate);
    }

    /// pools 的公开 getter 会省略动态数组 feeRules。这里按剩余字段解码，避开一次解出十个返回值造成的栈过深。
    function _pool(bytes32 poolId) internal view returns (PoolView memory pool) {
        (bool ok, bytes memory data) =
            address(core).staticcall(abi.encodeWithSelector(bytes4(keccak256("pools(bytes32)")), poolId));
        require(ok, "pool");
        pool = abi.decode(data, (PoolView));
    }

    struct ExpectedFill {
        address token;
        bool isBuy;
        uint256 tokenAmount;
        uint256 quoteAmount;
        uint256 quoteNet;
        uint256 price;
        uint256 platformFee;
        uint256 creatorFee;
        uint256 subpadFee;
    }

    struct SwapLog {
        bool isBuy;
        uint256 tokenAmount;
        uint8 tokenDecimal;
        address quoteToken;
        uint256 quoteAmount;
        uint256 fee;
        uint8 quoteDecimal;
        uint256 price;
    }

    function _fill(
        address token,
        bool isBuy,
        uint256 tokenAmount,
        uint256 quoteAmount,
        uint256 quoteNet,
        uint256 price,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 subpadFee
    ) internal pure returns (ExpectedFill memory fill) {
        fill.token = token;
        fill.isBuy = isBuy;
        fill.tokenAmount = tokenAmount;
        fill.quoteAmount = quoteAmount;
        fill.quoteNet = quoteNet;
        fill.price = price;
        fill.platformFee = platformFee;
        fill.creatorFee = creatorFee;
        fill.subpadFee = subpadFee;
    }

    /// 同一次成交日志里核对 SwapOnce 和手续费分成。
    /// getRecordedLogs 取走本次记录，所以两个事件必须在这一次调用里一起看。
    function _expectTrade(bytes32 poolId, ExpectedFill memory fill) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countSwap(logs, poolId, fill), 1);
        (uint256 platform, uint256 creator, uint256 subpad) = _sumFees(logs, poolId);
        assertEq(platform, fill.platformFee);
        assertEq(creator, fill.creatorFee);
        assertEq(subpad, fill.subpadFee);
    }

    function _countSwap(Vm.Log[] memory logs, bytes32 poolId, ExpectedFill memory fill)
        internal
        view
        returns (uint256 swaps)
    {
        bytes32 topic =
            keccak256("SwapOnce(bytes32,address,bool,address,uint256,uint8,address,uint256,uint256,uint8,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 4 || logs[i].topics[0] != topic || logs[i].topics[1] != poolId) continue;
            SwapLog memory swap = abi.decode(logs[i].data, (SwapLog));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), trader);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), fill.token);
            assertEq(swap.isBuy, fill.isBuy);
            assertEq(swap.tokenAmount, fill.tokenAmount);
            assertEq(swap.tokenDecimal, 18);
            assertEq(swap.quoteToken, address(usdc));
            assertEq(swap.quoteAmount, fill.quoteAmount);
            assertEq(swap.fee, fill.quoteAmount - fill.quoteNet);
            assertEq(swap.quoteDecimal, 6);
            assertEq(swap.price, fill.price);
            swaps++;
        }
    }

    function _sumFees(Vm.Log[] memory logs, bytes32 poolId)
        internal
        view
        returns (uint256 platformFee, uint256 creatorFee, uint256 subpadFee)
    {
        bytes32 topic = keccak256("FeeCharged(bytes32,uint8,address,uint8,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 4 || logs[i].topics[0] != topic || logs[i].topics[1] != poolId) {
                continue;
            }
            (uint8 decodedType, uint8 feeDecimal, uint256 feeAmount) = abi.decode(logs[i].data, (uint8, uint8, uint256));
            address feeTo = address(uint160(uint256(logs[i].topics[3])));
            assertEq(feeDecimal, 6);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(usdc));
            if (decodedType == uint8(ILaunchCore.FeeType.PLATFORM)) {
                assertEq(feeTo, address(core));
                platformFee += feeAmount;
            } else if (decodedType == uint8(ILaunchCore.FeeType.TOKEN_CREATOR)) {
                assertEq(feeTo, owner);
                creatorFee += feeAmount;
            } else if (decodedType == uint8(ILaunchCore.FeeType.SUBPAD)) {
                assertEq(feeTo, subpadFeeTo);
                subpadFee += feeAmount;
            }
        }
    }

    function _quoteForTokens(uint256 tokenAmount, uint256 price) internal pure returns (uint256) {
        return tokenAmount * price / PRICE_POINT;
    }

    function _tokensForQuote(uint256 quoteNet, uint256 price) internal pure returns (uint256) {
        return quoteNet * PRICE_POINT / price;
    }

    function _fee(uint256 quoteAmount, uint256 feeRate) internal pure returns (uint256) {
        return quoteAmount * feeRate / PERCENT_POINT;
    }

    function _share(uint256 amount, uint256 percent) internal pure returns (uint256) {
        return amount * percent / 100;
    }

    function _curvePrice(uint256 initPrice, uint256 sellSum) internal pure returns (uint256) {
        return initPrice + sellSum * 100 / 10_000;
    }
}
