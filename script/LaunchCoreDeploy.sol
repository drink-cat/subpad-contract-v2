// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {MockUsdc} from "../src/MockUsdc.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";
import {LaunchCore} from "../src/LaunchCore.sol";

/// 部署 LaunchCore 实现合约和 ERC1967 代理。
/// 代理的初始化数据会把部署者设为 owner。之后发币、升级都走代理地址，不要直接调用实现合约。
contract LaunchCoreDeploy is Script {
    function setUp() public {}

    function run() public {
        // 本地链用 ETH_LOCAL_PRIVATE_KEY。切到正式环境时改成 ETH_REAL_PRIVATE_KEY。
        // uint256 deployerPrivateKey = vm.envUint("ETH_LOCAL_PRIVATE_KEY");
        uint256 deployerPrivateKey = vm.envUint("ETH_REAL_PRIVATE_KEY");

        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 实现合约的构造函数会关掉初始化，owner 只在下面的代理初始化里生效。
        LaunchCore launchCore = new LaunchCore();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(launchCore), abi.encodeWithSelector(LaunchCore.initialize.selector, deployer));

        console.log("deployer addr = ", deployer);
        console.log("LaunchCore addr = ", address(launchCore));
        console.log("Proxy addr = ", address(proxy));

        vm.stopBroadcast();
    }
}
