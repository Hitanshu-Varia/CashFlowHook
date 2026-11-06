// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Deploy} from "./Deploy.s.sol";

/// @notice Fork deployment entry point. Writes `deploy/fork-addresses.json` for the web/indexer.
contract DeployFork is Deploy {
    function runFork() external returns (Deployment memory d) {
        d = deploy();

        vm.createDir("../deploy", true);

        string memory obj = "cashflowhook";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "markFeed", d.markFeed);
        vm.serializeAddress(obj, "strategyBureau", d.strategyBureau);
        vm.serializeAddress(obj, "feeStreamOracle", d.feeStreamOracle);
        vm.serializeAddress(obj, "rwaAdapter", d.rwaAdapter);
        vm.serializeAddress(obj, "navSignalOracle", d.navSignalOracle);
        vm.serializeAddress(obj, "agentPassVerifier", d.agentPassVerifier);
        vm.serializeAddress(obj, "creditEngine", d.creditEngine);
        vm.serializeAddress(obj, "aqua", d.aqua);
        vm.serializeAddress(obj, "aquaCreditLine", d.aquaCreditLine);
        vm.serializeAddress(obj, "spanRouter", d.spanRouter);
        vm.serializeAddress(obj, "liquidity", d.liquidity);
        vm.serializeAddress(obj, "hook", d.hook);
        string memory json = vm.serializeAddress(obj, "receipts", d.receipts);
        vm.writeJson(json, "../deploy/fork-addresses.json");
        console2.log("wrote ../deploy/fork-addresses.json");
    }
}
