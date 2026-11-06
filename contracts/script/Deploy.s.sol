// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CreditEngine} from "../src/CreditEngine.sol";
import {MarkFeed} from "../src/MarkFeed.sol";
import {StrategyBureau} from "../src/StrategyBureau.sol";
import {FeeStreamOracle} from "../src/FeeStreamOracle.sol";
import {RwaCollateralAdapter} from "../src/RwaCollateralAdapter.sol";
import {NavSignalOracle} from "../src/NavSignalOracle.sol";
import {AgentPassVerifier} from "../src/AgentPassVerifier.sol";
import {ReceiptsRegistry} from "../src/ReceiptsRegistry.sol";
import {AquaCreditLine} from "../src/AquaCreditLine.sol";
import {MockAqua} from "../src/mocks/MockAqua.sol";
import {MockLiquidity} from "../src/mocks/MockLiquidity.sol";
import {SpanVMRouter} from "../src/SpanVMRouter.sol";
import {PortfolioMarginHook} from "../src/PortfolioMarginHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice Deploys the full v3 stack. Every external address comes from the environment; nothing
///         is hard-coded. On a local Anvil fork the official Aqua address may be absent, in which
///         case a labelled MockAqua is deployed so the demo remains runnable.
contract Deploy is Script {
    struct Deployment {
        address markFeed;
        address strategyBureau;
        address feeStreamOracle;
        address rwaAdapter;
        address navSignalOracle;
        address agentPassVerifier;
        address creditEngine;
        address aqua;
        address aquaCreditLine;
        address spanRouter;
        address liquidity;
        address hook;
        address receipts;
    }

    function run() external returns (Deployment memory d) {
        d = deploy();
    }

    function deploy() internal returns (Deployment memory d) {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        address feeSigner = vm.envOr("ORACLE_SIGNER", deployer);
        address navSigner = vm.envOr("NAV_SIGNER", deployer);
        address backendSigner = vm.envOr("BACKEND_SIGNER", deployer);
        address aquaAddr = vm.envOr("AQUA_ADDR", address(0));
        address poolManager = vm.envOr("POOL_MANAGER_BASE", address(0));
        bytes32 hookSalt = vm.envOr("HOOK_SALT", bytes32(0));

        vm.startBroadcast(deployerKey);

        MarkFeed markFeed = new MarkFeed();
        StrategyBureau bureau = new StrategyBureau(deployer);
        FeeStreamOracle feeOracle = new FeeStreamOracle(feeSigner, address(bureau));
        bureau.setOracle(address(feeOracle));

        RwaCollateralAdapter adapter = new RwaCollateralAdapter();
        NavSignalOracle navOracle = new NavSignalOracle(navSigner, address(adapter));
        adapter.setNavOracle(address(navOracle));

        CreditEngine engine = new CreditEngine(
            address(markFeed),
            address(feeOracle),
            address(0),
            address(adapter),
            address(navOracle),
            address(0),
            address(0)
        );

        AgentPassVerifier verifier = new AgentPassVerifier(backendSigner, address(engine));
        engine.setAgentVerifier(address(verifier));

        MockLiquidity liquidity = new MockLiquidity();
        SpanVMRouter router = new SpanVMRouter(address(engine), address(liquidity));
        engine.setRouter(address(router));

        address aqua = aquaAddr;
        if (aqua == address(0)) {
            aqua = address(new MockAqua());
            console2.log("AQUA_ADDR unset: deployed MockAqua at", aqua);
        }
        AquaCreditLine line = new AquaCreditLine(address(engine), aqua);
        engine.setLine(address(line));

        // A hook address must encode its permission flags. HOOK_SALT is produced by MineHook.s.sol;
        // without it the hook is still deployed, but the pool manager will reject the address.
        PortfolioMarginHook hook;
        if (hookSalt != bytes32(0)) {
            hook = new PortfolioMarginHook{salt: hookSalt}(IPoolManager(poolManager), address(engine));
        } else {
            hook = new PortfolioMarginHook(IPoolManager(poolManager), address(engine));
            console2.log("HOOK_SALT unset: hook deployed without permission mining");
        }
        engine.setHook(address(hook));

        ReceiptsRegistry receipts = new ReceiptsRegistry();

        vm.stopBroadcast();

        d = Deployment({
            markFeed: address(markFeed),
            strategyBureau: address(bureau),
            feeStreamOracle: address(feeOracle),
            rwaAdapter: address(adapter),
            navSignalOracle: address(navOracle),
            agentPassVerifier: address(verifier),
            creditEngine: address(engine),
            aqua: aqua,
            aquaCreditLine: address(line),
            spanRouter: address(router),
            liquidity: address(liquidity),
            hook: address(hook),
            receipts: address(receipts)
        });
    }
}
