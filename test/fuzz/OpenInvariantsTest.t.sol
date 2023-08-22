// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// pragma solidity ^0.8.18;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

// contract InvariantsTest is StdInvariant, Test {
//     DeployDSC public deployer;
//     DSCEngine public dsce;
//     DecentralizedStableCoin public dsc;
//     address public weth;
//     address public wbtc;
//     HelperConfig public config;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dsce, config) = deployer.run();
//         (,,weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dsce));
//     }

//     function invariantProtocolMustHaveMoreValueThanTotalSupply() public view {
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint256 wbthValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

//         assert(wethValue + wbthValue >= totalSupply);
//     }
// }
