// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CreditEngine} from "../src/CreditEngine.sol";
import {MarkFeed} from "../src/MarkFeed.sol";
import {RwaCollateralAdapter} from "../src/RwaCollateralAdapter.sol";
import {NavSignalOracle} from "../src/NavSignalOracle.sol";
import {ReceiptsRegistry} from "../src/ReceiptsRegistry.sol";

/// @notice Seeds the fork deployment with marks, a NAV record, and one demo account.
/// @dev All token addresses come from env. Missing values are skipped, never guessed.
contract Configure is Script {
    function run() external {
        string memory json = vm.readFile("../deploy/fork-addresses.json");
        address engineAddr = vm.parseJsonAddress(json, ".creditEngine");
        address markFeedAddr = vm.parseJsonAddress(json, ".markFeed");
        address adapterAddr = vm.parseJsonAddress(json, ".rwaAdapter");
        address navOracleAddr = vm.parseJsonAddress(json, ".navSignalOracle");
        address receiptsAddr = vm.parseJsonAddress(json, ".receipts");
        address routerAddr = vm.parseJsonAddress(json, ".spanRouter");

        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        uint256 borrowerKey = vm.envOr("BORROWER_KEY", uint256(0));
        address borrower = borrowerKey == 0 ? address(0) : vm.addr(borrowerKey);
        uint256 accountId = vm.envOr("DEMO_ACCOUNT_ID", uint256(1));

        address stockToken = vm.envOr("STOCK_TOKEN_BASE", address(0));
        uint256 lpTokenId = vm.envOr("LP_TOKEN_ID", uint256(42));
        address equityAsset = vm.envOr("R1_ASSET_BASE", address(0));
        address treasuryAsset = vm.envOr("R2_ASSET_ID", address(0));

        vm.startBroadcast(deployerKey);

        if (stockToken != address(0)) {
            MarkFeed(markFeedAddr).setMark(
                bytes32(uint256(uint160(stockToken))),
                vm.envOr("STOCK_MARK_WAD", uint256(100e18)),
                uint64(block.timestamp)
            );
        }
        MarkFeed(markFeedAddr).setMark(
            bytes32(lpTokenId), vm.envOr("LP_MARK_WAD", uint256(50e18)), uint64(block.timestamp)
        );

        if (equityAsset != address(0)) {
            RwaCollateralAdapter(adapterAddr).registerAsset(
                equityAsset,
                1,
                vm.envOr("R1_TRANSFER_RESTRICTED", false),
                uint8(vm.envOr("R1_DECIMALS", uint256(18))),
                false
            );
            RwaCollateralAdapter(adapterAddr).setEquityMark(
                equityAsset, vm.envOr("R1_MARK_WAD", uint256(100e18)), uint64(block.timestamp)
            );
        }
        if (treasuryAsset != address(0)) {
            RwaCollateralAdapter(adapterAddr).registerAsset(
                treasuryAsset, 2, false, uint8(vm.envOr("R2_DECIMALS", uint256(18))), true
            );
        }

        vm.stopBroadcast();

        // NAV records are signed by the dedicated NAV signer. Skip the post if the key is absent
        // so the local fork still starts; the UI will flag the missing record.
        uint256 navKey = vm.envOr("NAV_SIGNER_KEY", uint256(0));
        if (treasuryAsset != address(0) && navKey != 0) {
            NavSignalOracle.NavRecord memory r = NavSignalOracle.NavRecord({
                asset: treasuryAsset,
                navPerShareWad: vm.envOr("NAV_PER_SHARE_WAD", uint256(1e18)),
                accrualPerSecondWad: vm.envOr("NAV_ACCRUAL_PER_SECOND_WAD", uint256(1e12)),
                observedAt: uint64(vm.envOr("NAV_OBSERVED_AT", uint256(block.timestamp))),
                gateOpen: vm.envOr("NAV_GATE_OPEN", true),
                sourceTxHash: vm.envOr("NAV_SOURCE_TX_HASH", bytes32(0))
            });
            bytes memory sig = _sign(navKey, NavSignalOracle(navOracleAddr).hashNavRecord(r));
            vm.broadcast(deployerKey);
            NavSignalOracle(navOracleAddr).postNav(sig, r);
            vm.stopBroadcast();
        }

        if (borrower != address(0) && stockToken != address(0)) {
            vm.startBroadcast(borrowerKey);
            CreditEngine(engineAddr).onboard(
                accountId,
                stockToken,
                vm.envOr("STOCK_UNITS_WAD", uint256(10e18)),
                lpTokenId,
                vm.envOr("LP_UNITS_WAD", uint256(20e18))
            );
            if (equityAsset != address(0)) {
                CreditEngine(engineAddr).setRwaPosition(
                    accountId, equityAsset, vm.envOr("R1_UNITS_WAD", uint256(10e18))
                );
            }
            if (treasuryAsset != address(0)) {
                CreditEngine(engineAddr).setRwaPosition(
                    accountId, treasuryAsset, vm.envOr("R2_UNITS_WAD", uint256(1000e18))
                );
            }
            address agent = vm.envOr("AGENT_ADDR", address(0));
            if (agent != address(0)) {
                CreditEngine(engineAddr).setAgent(accountId, agent);
                ReceiptsRegistry(receiptsAddr).setAgent(agent, true);
            }
            CreditEngine(engineAddr).registerUnwinder(accountId, routerAddr);
            vm.stopBroadcast();
        }

        console2.log("configured demo account", accountId);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
