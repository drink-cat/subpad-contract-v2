// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

// 百分比的定点基数。100% = 10000，5% = 500，0.1% = 10。
uint256 constant PERCENT_POINT = 1e4;
// 价格的定点基数。价格表示「1 枚完整代币值多少报价币」，报价币数量与代币数量同为 18 位精度。
uint256 constant PRICE_POINT = 1e18;
// 与 PERCENT_POINT 相同，留给手续费计算使用。
uint256 constant FEE_POINT = PERCENT_POINT;

interface ILaunchCore {
    /// 发币参数。只有 LaunchCore 的 owner 能调用 createToken。
    struct CreateTokenParams {
        bool useMockSwap; // 是否走合约内的模拟撮合。目前 mockSwap 不读取这个开关。
        string tokenName;
        string tokenSymbol;
        uint256 tokenDecimals; // 预留。当前 Token 合约固定 18 位小数，这个字段不会传进去。
        uint256 totalSupply; // 一次性铸造的总量，全部进 LaunchCore，作为可卖出的库存。
        address quoteToken; // 报价币，例如 USDC。买卖的手续费和池子收支都用它。
        uint256 initPrice; // 起始价格，单位 PRICE_POINT。卖出量为 0 时的曲线价格。
        uint256 subpadId; // 子 pad id。0 表示没有子 pad，手续费按两方分成。
        address subpadFeeTo; // 子 pad 的费用接收地址。subpadId 为 0 时不会用到。
    }

    /// 一笔模拟成交的输入。tokenAmount 与 quoteTokenAmount 二选一，另一个填 0。
    /// 两个都非 0 时，只认 tokenAmount。
    struct SwapParams {
        bytes32 poolId;
        int256 tokenAmount; // 正数=用报价币买代币。负数=卖出代币换报价币。0=这次不按代币数量成交。
        int256 quoteTokenAmount; // 正数=支付这么多报价币来买。负数=按这么多报价币的总额来卖。0=这次不按报价币数量成交。
    }

    /// 一个代币池。价格随已卖出数量 sellSum 上升，买和卖都改这个数量。
    struct PoolInfo {
        bool useMockSwap; // 是否使用 mock swap。创建时写入，成交函数当前不检查它。
        bytes32 poolId;
        address creator; // createToken 的调用者。该函数只能由 owner 调用。
        address token; // 本池发行的代币。地址为 0 表示池子不存在。
        address quoteToken; // 报价币。
        uint256 initPrice; // 起始价格，单位 PRICE_POINT。
        uint256 sellSum; // 净卖出数量，18 位精度。买入增加，卖出减少，价格由它决定。不能卖超过这个数。
        uint256 subpadId; // 子 pad id。0 表示没有子 pad。
        address subpadFeeTo; // 子 pad 费用接收地址。
        uint256 feeRate; // 手续费率，4 位小数。无子 pad 为 10（0.1%），有子 pad 为 15（0.15%）。
        FeeRule[] feeRules; // 手续费分成。各 percent 之和为 100%。最后一条拿走向下取整的余数。
    }

    /// 手续费归谁。链下按这个枚举区分平台、发币人和子 pad。
    enum FeeType {
        PLATFORM,
        TOKEN_CREATOR,
        SUBPAD
    }

    /// 一条分成规则。percent 使用 PERCENT_POINT，50% = 5000。
    struct FeeRule {
        FeeType feeType; // 费用类型
        uint256 percent; // 占本笔手续费的比例，不是占成交额的比例。
        address feeTo; // 这笔分成的收款地址。
    }

    /// 发币并建池之后发出。tickSpacing 目前固定为 0，模拟曲线不用 Uniswap 的 tick。
    event TokenCreated(
        bytes32 indexed poolId,
        address indexed creator,
        address indexed token,
        string tokenName,
        string tokenSymbol,
        address quoteToken,
        string quoteTokenSymbol,
        uint256 launchSupply,
        int24 tickSpacing
    );

    /// 一笔手续费分成已经从交易者的报价币划走。
    /// 一次成交会按 feeRules 发多条。part 为 0 的规则不发这个事件。
    event FeeCharged(
        bytes32 indexed poolId,
        FeeType feeType,
        address indexed feeToken,
        uint8 feeDecimal,
        uint256 feeAmount,
        address indexed feeTo
    );

    /// 一次成交。
    /// isBuy 为 true 表示买入代币。tokenAmount 始终为正。
    /// quoteAmount 是扣费前的报价币。fee 是从这笔报价币里扣出的手续费，和报价币同一单位。
    /// 进出池子的报价币 = quoteAmount - fee。手续费按分成另外从交易者余额转走。
    /// price 是这笔成交使用的曲线价格，sellSum 在成交后才更新，所以事件里的价格不含本笔造成的变化。
    event SwapOnce(
        bytes32 indexed poolId,
        address indexed trader,
        bool isBuy,
        address indexed token,
        uint256 tokenAmount,
        uint8 tokenDecimal,
        address quoteToken,
        uint256 quoteAmount,
        uint256 fee,
        uint8 quoteDecimal,
        uint256 price
    );
}
