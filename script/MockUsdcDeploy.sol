// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {MockUsdc} from "../src/MockUsdc.sol";
// import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";

/// 部署测试用报价币。不是代理，部署者就是 MockUsdc 的 owner，可以用 mint 给地址打币。
contract MockUsdcDeploy is Script {
    function setUp() public {}

    function run() public {
        // 本地链用 ETH_LOCAL_PRIVATE_KEY。切到正式环境时改成 ETH_REAL_PRIVATE_KEY。
        uint256 deployerPrivateKey = vm.envUint("ETH_LOCAL_PRIVATE_KEY");
        // uint256 deployerPrivateKey = vm.envUint("ETH_REAL_PRIVATE_KEY");

        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        MockUsdc mockUSDC = new MockUsdc();

        console.log("deployer addr = ", deployer);
        console.log("MockUsdc addr = ", address(mockUSDC));

        vm.stopBroadcast();
    }
}
