// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {MockUsdc} from "../src/MockUsdc.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";
import {LaunchCore} from "../src/LaunchCore.sol";

/// 给已经部署的 LaunchCore 代理换上新的实现合约。
/// 调用者必须是代理的 owner。upgradeToAndCall 的 data 传空，只升级代码，不跑额外初始化。
contract LaunchCoreDeploy is Script {
    function setUp() public {}

    function run() public {
        // 本地链用 ETH_LOCAL_PRIVATE_KEY。切到正式环境时改成 ETH_REAL_PRIVATE_KEY。
        // uint256 deployerPrivateKey = vm.envUint("ETH_LOCAL_PRIVATE_KEY");
    // 本地网已部署的代理地址。换网时改成对应代理。
        // address proxyAddress = 0x88D1aF96098a928eE278f162c1a84f339652f95b;

    // 正式网用 ETH_REAL_PRIVATE_KEY。
        uint256 deployerPrivateKey = vm.envUint("ETH_REAL_PRIVATE_KEY");
            // 本地网已部署的代理地址。换网时改成对应代理。
        address proxyAddress = 0x66A2a634960b97875D1FC5dc902aadd26978a3F0;

        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 新的实现。构造函数只负责禁止直接初始化，存储仍留在下面的代理里。
        LaunchCore launchCore = new LaunchCore();


        LaunchCore proxy = LaunchCore(proxyAddress);
        proxy.upgradeToAndCall(address(launchCore), "");

        console.log("deployer addr = ", deployer);
        console.log("LaunchCore addr = ", address(launchCore));
        console.log("Proxy addr = ", address(proxy));

        vm.stopBroadcast();
    }
}
