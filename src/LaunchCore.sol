// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {Token} from "./Token.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILaunchCore, PERCENT_POINT, PRICE_POINT} from "./interfaces/ILaunchCore.sol";
import {PoolInfoLib} from "./libraries/PoolInfoLib.sol";

/// 发币和模拟成交。
/// 通过 UUPS 代理使用：实现合约构造时关掉初始化，真正的 owner 在代理的 initialize 里设置。
/// 代币总量铸在本合约里。用户买入时合约付出代币、收进扣费后的报价币；卖出时方向相反。
/// 手续费始终从交易者的报价币余额转给分成地址，不从池子库存里扣。
contract LaunchCore is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    ILaunchCore
{
    using PoolInfoLib for PoolInfo;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    /// 可以暂停和恢复。管理员角色仍是 owner，用来把这个角色转给别人。
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// poolId => 池子。poolId = keccak256(abi.encode(创建者, 代币地址, 报价币地址))。
    mapping(bytes32 poolId => PoolInfo) public pools;

    /// 实现合约不能直接初始化，避免有人绕过代理把 owner 设走。
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// 代理部署时调用一次，把 initialOwner 设为管理员。发币和升级都只允许这个地址。
    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        __AccessControl_init();
        __Pausable_init();
        _grantSecurityRoles(initialOwner);
    }

    /// 旧代理已经跑过 initialize 时，由 owner 再调用一次，补上暂停角色。
    /// 重复调用只是再次授权，不会改发币和成交逻辑。
    function initSecurity() public onlyOwner {
        _grantSecurityRoles(owner());
    }

    /// 暂停发币和成交。已经暂停时会回退。
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// 恢复发币和成交。
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// owner 同时是角色管理员和暂停人，之后可以用 grantRole 把暂停权交给别人。
    function _grantSecurityRoles(address account) private {
        _grantRole(DEFAULT_ADMIN_ROLE, account);
        _grantRole(PAUSER_ROLE, account);
    }

    /// UUPS 升级入口的权限检查。新实现地址由 owner 通过 upgradeToAndCall 传入。
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// 发行一种代币并建池。
    /// 新代币的 owner 是本合约（代理地址），总量铸给本合约。
    /// subpadId == 0：费率 0.1%，平台和发币人各 50%。
    /// subpadId != 0：费率 0.15%，平台 40%、发币人 40%、子 pad 20%。
    /// 平台费进本合约，发币人费进 msg.sender。本函数只能由 owner 调用，所以发币人费目前进 owner。
    function createToken(CreateTokenParams calldata params) public whenNotPaused {
        // 部署项目代币。Token 构造函数把 owner 设为调用方，也就是本合约，后面才能 mint。
        Token token = new Token(params.tokenName, params.tokenSymbol);
        // 总量一次铸进本合约，作为买入时可以转出的库存。
        token.mint(address(this), params.totalSupply);

        // 创建者、代币、报价币三者确定唯一池子。每次 new 出来的代币地址不同，poolId 不会撞车。
        bytes32 poolId = keccak256(abi.encode(msg.sender, address(token), params.quoteToken));

        // 按有没有子 pad 选择费率和分成。数字是 4 位小数，10000 = 100%。
        uint256 feeRate;
        FeeRule[] memory feeRules;
        if (params.subpadId == 0) {
            // 费率 10 = 0.1%。平台、发币人各 5000 = 50%。
            feeRate = 10;
            feeRules = new FeeRule[](2);
            feeRules[0] = FeeRule({feeType: FeeType.PLATFORM, percent: 5000, feeTo: address(this)});
            feeRules[1] = FeeRule({feeType: FeeType.TOKEN_CREATOR, percent: 5000, feeTo: msg.sender});
        } else {
            // 费率 15 = 0.15%。平台 4000、发币人 4000、子 pad 2000。
            feeRate = 15;
            feeRules = new FeeRule[](3);
            feeRules[0] = FeeRule({feeType: FeeType.PLATFORM, percent: 4000, feeTo: address(this)});
            feeRules[1] = FeeRule({feeType: FeeType.TOKEN_CREATOR, percent: 4000, feeTo: msg.sender});
            feeRules[2] = FeeRule({feeType: FeeType.SUBPAD, percent: 2000, feeTo: params.subpadFeeTo});
        }

        // 写入池子。sellSum 从 0 开始，第一笔成交的价格就是 initPrice。
        PoolInfo storage pool = pools[poolId];
        pool.useMockSwap = params.useMockSwap;
        pool.poolId = poolId;
        pool.creator = msg.sender;
        pool.token = address(token);
        pool.quoteToken = params.quoteToken;
        pool.initPrice = params.initPrice;
        pool.sellSum = 0;
        pool.subpadId = params.subpadId;
        pool.subpadFeeTo = params.subpadFeeTo;
        pool.feeRate = feeRate;
        // feeRules 在 storage 里是动态数组，不能整体赋值，只能逐条追加。
        for (uint256 i = 0; i < feeRules.length; i++) {
            pool.feeRules.push(feeRules[i]);
        }

        // 池子写完再发事件。报价币符号从报价币合约读取。模拟曲线没有 tick，tickSpacing 记 0。
        emit TokenCreated(
            poolId,
            msg.sender,
            address(token),
            params.tokenName,
            params.tokenSymbol,
            params.quoteToken,
            IERC20Metadata(params.quoteToken).symbol(),
            params.totalSupply,
            0
        );
    }

    /// 按当前曲线价格模拟一笔成交。谁都可以调用，调用前须把相关代币 approve 给本合约。
    ///
    /// 输入二选一：
    /// - tokenAmount 非 0：按代币数量成交。先用现价换成报价币总额，再从这笔总额扣费。
    ///   买入时用户实际换到的代币就是指定数量；扣费后的报价币进入池子。
    /// - 否则 quoteTokenAmount 非 0：按报价币总额成交。先从这笔总额扣费，再用剩下的报价币换代币。
    ///   买入时用户付出的报价币是指定总额，换到的代币按扣费后的金额计算。
    ///
    /// 买入：交易者支付 quoteNet 给池子，池子支付 tokenAmount 给交易者，sellSum 增加，之后价格变高。
    /// 卖出：交易者支付 tokenAmount 给池子，池子支付 quoteNet 给交易者，sellSum 减少。
    /// 卖出不能超过 sellSum，也就是不能卖出比当前净买入更多的代币。
    ///
    /// 手续费在上面两种情况里都是另外从交易者的报价币余额转走。
    /// 因此卖出时交易者要自备手续费，报价币净入账 = quoteNet - fee，不是 quoteNet。
    function mockSwap(SwapParams calldata swapParams) public nonReentrant whenNotPaused {
        PoolInfo storage pool = pools[swapParams.poolId];
        // 没建过的池子，token 是零地址。
        require(pool.token != address(0), "Pool not found");

        // 先定价再改 sellSum。这一笔买入或卖出全程用同一个价格。
        uint256 currentPrice = pool.getCurrentPrice();
        require(currentPrice > 0, "price");

        bool isBuy;
        uint256 tokenAmount;
        uint256 quoteAmount; // 扣费前的报价币总额，手续费按它算。
        uint256 quoteNet; // 扣费后剩下的报价币，才是进出池子的金额。
        if (swapParams.tokenAmount != 0) {
            // 按代币数量成交。两个数量都填了时也走这里，报价币数量被忽略。
            // 正数是买代币，负数是卖代币。
            isBuy = swapParams.tokenAmount > 0;
            tokenAmount = _abs(swapParams.tokenAmount);
            // 报价币总额 = 代币数量 * 现价 / 1e18。
            quoteAmount = tokenAmount.mulDivDown(currentPrice, PRICE_POINT);
            quoteNet = _takeQuoteFee(pool, quoteAmount);
        } else if (swapParams.quoteTokenAmount != 0) {
            // 按报价币总额成交。正数是拿报价币买代币，负数是按这个总额卖出代币。
            isBuy = swapParams.quoteTokenAmount > 0;
            quoteAmount = _abs(swapParams.quoteTokenAmount);
            // 先扣费，再用剩下的报价币换代币：代币数量 = quoteNet * 1e18 / 现价。
            quoteNet = _takeQuoteFee(pool, quoteAmount);
            tokenAmount = quoteNet.mulDivDown(PRICE_POINT, currentPrice);
        } else {
            revert("empty swap");
        }

        IERC20 quoteToken = IERC20(pool.quoteToken);
        IERC20 launchToken = IERC20(pool.token);
        if (isBuy) {
            // 手续费已从交易者余额划走。这里只收扣费后的报价币，并把代币转给交易者。
            if (quoteNet > 0) quoteToken.safeTransferFrom(msg.sender, address(this), quoteNet);
            if (tokenAmount > 0) launchToken.safeTransfer(msg.sender, tokenAmount);
            // 净卖出增加，下一笔的曲线价格变高。
            pool.sellSum += tokenAmount;
        } else {
            // 只能卖回已经净卖出的数量，不能把初始库存再卖出去。
            require(pool.sellSum >= tokenAmount, "sellSum");
            // 交易者退回代币，池子付出扣费后的报价币。手续费另外从交易者的报价币余额扣。
            if (tokenAmount > 0) launchToken.safeTransferFrom(msg.sender, address(this), tokenAmount);
            if (quoteNet > 0) quoteToken.safeTransfer(msg.sender, quoteNet);
            // 净卖出减少，下一笔的曲线价格变低。
            pool.sellSum -= tokenAmount;
        }

        // 事件里的价格是本笔开始时的价格，不含 sellSum 刚发生的变化。
        // fee 是本笔手续费总额。进出池子的报价币是 quoteAmount - fee，不再单独放进事件。
        _emitSwapOnce(pool, isBuy, tokenAmount, quoteAmount, quoteAmount - quoteNet, currentPrice);
    }

    /// 发出 SwapOnce。单独成函数，避免 mockSwap 里局部变量过多导致栈太深。
    /// 事件里的小数位取自代币合约，方便链下直接换算，不参与计价。
    function _emitSwapOnce(
        PoolInfo storage pool,
        bool isBuy,
        uint256 tokenAmount,
        uint256 quoteAmount,
        uint256 fee,
        uint256 price
    ) private {
        emit SwapOnce(
            pool.poolId,
            msg.sender,
            isBuy,
            pool.token,
            tokenAmount,
            IERC20Metadata(pool.token).decimals(),
            pool.quoteToken,
            quoteAmount,
            fee,
            IERC20Metadata(pool.quoteToken).decimals(),
            price
        );
    }

    /// 从交易者的报价币里扣手续费，并按 feeRules 分给各收款地址。
    /// 返回扣费后剩余的报价币 quoteNet，由 mockSwap 决定这笔钱进池子还是打给交易者。
    ///
    /// 除最后一条规则外都向下取整。最后一条拿走 fee - 已分配，保证分成之和等于手续费，尘埃不会留在交易者或合约里。
    /// 某一条分成为 0 时跳过转账，也不发 FeeCharged。
    function _takeQuoteFee(PoolInfo storage pool, uint256 quoteAmount) private returns (uint256 quoteNet) {
        // 手续费 = 报价币总额 * 费率 / 10000，向下取整。费率为 0 或总额太小时，fee 可以是 0。
        uint256 fee = quoteAmount.mulDivDown(pool.feeRate, PERCENT_POINT);
        uint256 distributed;
        // 小数位只写进事件，方便链下换算，不参与分成计算。
        uint8 feeDecimal = IERC20Metadata(pool.quoteToken).decimals();
        IERC20 quoteToken = IERC20(pool.quoteToken);
        uint256 ruleCount = pool.feeRules.length;
        for (uint256 i = 0; i < ruleCount; i++) {
            FeeRule storage rule = pool.feeRules[i];
            // 前面的规则按比例向下取整。最后一条拿走还没分掉的部分，分成之和才等于 fee。
            uint256 part = i + 1 == ruleCount ? fee - distributed : fee.mulDivDown(rule.percent, PERCENT_POINT);
            distributed += part;
            // 这一条分到 0，就不转账，也不发事件。
            if (part == 0) continue;
            // 从交易者的报价币余额直接转给收款地址，不经过池子。
            quoteToken.safeTransferFrom(msg.sender, rule.feeTo, part);
            emit FeeCharged(pool.poolId, rule.feeType, pool.quoteToken, feeDecimal, part, rule.feeTo);
        }
        // 调用方用这个余额去收币或付币，里面已经不含手续费。
        quoteNet = quoteAmount - fee;
    }

    /// 有符号成交数量转成正数。int256 最小值取负会溢出，直接拒绝。
    function _abs(int256 value) private pure returns (uint256) {
        require(value != type(int256).min, "amount");
        // casting to 'uint256' is safe because value is not int256.min, and a negative value is negated first
        // forge-lint: disable-next-line(unsafe-typecast)
        return value < 0 ? uint256(-value) : uint256(value);
    }
}
