// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// LaunchCore 发币时创建的项目代币。
/// 部署者成为 owner。LaunchCore 用 new Token 创建它，所以 owner 是 LaunchCore 代理。
/// 精度固定 18 位。创建时按 totalSupply 一次性铸给 LaunchCore，之后由 LaunchCore 在买卖中转出或收回。
contract Token is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}

    /// 覆盖 ERC20 的 18 位默认值，把精度明确固定下来。
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// 只有 owner（LaunchCore）能增发。发币时用来把总量铸给池子。
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /// 只有 owner 能烧毁指定地址的余额，调用前该地址须把额度 approve 给 owner。
    function burn(address from, uint256 amount) public onlyOwner {
        _burn(from, amount);
    }

    /// 任何人烧毁自己的余额。
    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }
}
