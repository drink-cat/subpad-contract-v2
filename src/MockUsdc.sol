// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// 测试用报价币，精度 6 位，对齐 USDC。
/// 正式环境应换成真实的报价币。LaunchCore 只通过 IERC20 与它交互，手续费事件里的小数位读自 decimals()。
contract MockUsdc is ERC20, Ownable {
    constructor() ERC20("Mock USDC", "MockUSDC") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// 部署者给任意地址铸币。
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /// 调用者给自己铸币，方便本地领取测试币。没有额度限制。
    function mintSelfFree(uint256 amount) public {
        _mint(msg.sender, amount);
    }

    /// 只有 owner 能烧毁指定地址的余额。
    function burn(address from, uint256 amount) public onlyOwner {
        _burn(from, amount);
    }

    /// 任何人烧毁自己的余额。
    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }
}
